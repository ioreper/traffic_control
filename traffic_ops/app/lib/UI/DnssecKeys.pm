package UI::DnssecKeys;
#
# Copyright 2015 Comcast Cable Communications Management, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
#

# JvD Note: you always want to put Utils as the first use. Sh*t don't work if it's after the Mojo lines.
use UI::Utils;

use Mojo::Base 'Mojolicious::Controller';
use Data::Dumper;
use UI::DeliveryService;
use API::Cdn;
use Scalar::Util qw(looks_like_number);

sub add {
	my $self = shift;

	#get a list of cdns from parameters
	&navbarpage($self);
	my @cdns = $self->db->resultset('Parameter')->search( { name => 'CDN_Name' } )->get_column('value')->all();

	$self->stash(
		msgs   => [],
		dnssec => {
			ttl      => "60",
			k_expiry => "365",
			z_expiry => "30",
		},
		cdns => \@cdns,
	);
}

sub create {
	my $self     = shift;
	my $cdn_name = $self->param('dnssec.cdn_name');
	my $ttl      = $self->param('dnssec.ttl');
	my $z_expiry = $self->param('dnssec.z_expiry');
	my $k_expiry = $self->param('dnssec.k_expiry');
	&stash_role($self);

	if ( !&is_admin($self) ) {
		$self->flash( alertmsg => "Keys can only be generated by admins!" );
		return $self->redirect_to("/cdns/dnsseckeys/add");
	}

	if ( $self->is_valid() ) {

		#get profile_id for cdn
		my $profile_id = $self->get_profile_id_by_cdn($cdn_name);

		#find or create dnssec.enabled param
		my $param_id = $self->db->resultset('Parameter')->find_or_create(
			{
				name        => 'dnssec.enabled',
				config_file => 'CRConfig.json',
				value       => 'true',
			}
		);
		$param_id = $param_id->id;

		#associate param to cdn profile_id
		my $pp_insert = $self->db->resultset('ProfileParameter')->find_or_create(
			{
				profile   => $profile_id,
				parameter => $param_id,
			}
		);

		#create keys
		my $name = $self->db->resultset('Parameter')->search(
			{ -and => [ 'me.name' => 'domain_name', 'me.config_file' => 'CRConfig.json', 'profile.id' => $profile_id ] },
			{
				join => { profile_parameters => { profile => undef } },
			}
		)->get_column('value')->single();

		my $response_container = $self->riak_ping();
		my $ping_response      = $response_container->{response};
		if ( $ping_response->is_success ) {
			my $response_container = $self->generate_store_dnssec_keys( $cdn_name, $name, $ttl, $k_expiry, $z_expiry );
			my $response = $response_container->{response};
			if ( $response->is_success ) {
				&log( $self, "Created dnssec keys for CDN $cdn_name", "UICHANGE" );
				$self->flash( message => "Successfully created dnssec keys for: $cdn_name" );
			}
			else {
				$self->flash( { "SSL keys for $name could not be created.  Response was" . $response->{_content} } );
			}
		}
		else {
			my @cdns = $self->db->resultset('Parameter')->search( { name => 'CDN_Name' } )->get_column('value')->all();
			$self->stash(
				dnssec => {
					cdn_name => $cdn_name,
					ttl      => $ttl,
					k_expiry => $k_expiry,
					z_expiry => $z_expiry,
				},
				cdns        => \@cdns,
				fbox_layout => 1
			);
			my @msgs;
			push( @msgs, $ping_response->{_content} );
			$self->stash( msgs => \@msgs );
			$self->build_stash();
			return $self->render("dnssec_keys/add");
		}

		return $self->redirect_to("/cdns/dnsseckeys/add");
	}
	else {
		$self->build_stash();
		$self->stash( msgs => [] );
		$self->render("dnssec_keys/add");
	}
}

sub build_stash {
	my $self     = shift;
	my $cdn_name = $self->param('dnssec.cdn_name');
	my $ttl      = $self->param('dnssec.ttl');
	my $z_expiry = $self->param('dnssec.z_expiry');
	my $k_expiry = $self->param('dnssec.k_expiry');
	my @cdns     = $self->db->resultset('Parameter')->search( { name => 'CDN_Name' } )->get_column('value')->all();
	$self->stash(
		dnssec => {
			cdn_name => $cdn_name,
			ttl      => $ttl,
			k_expiry => $k_expiry,
			z_expiry => $z_expiry,
		},
		cdns        => \@cdns,
		fbox_layout => 1
	);
}

sub is_valid {
	my $self     = shift;
	my $cdn_name = $self->param('dnssec.cdn_name');
	my $ttl      = $self->param('dnssec.ttl');
	my $z_expiry = $self->param('dnssec.z_expiry');
	my $k_expiry = $self->param('dnssec.k_expiry');

	if ( $cdn_name eq "default" ) {
		$self->field('dnssec.cdn_name')->is_equal( "", "Please choose a CDN" );
	}

	if ( !looks_like_number($ttl) ) {
		$self->field('dnssec.ttl')->is_equal( "", "$ttl is not a number" );
	}
	if ( !looks_like_number($z_expiry) ) {
		$self->field('dnssec.z_expiry')->is_equal( "", "$z_expiry is not a number" );
	}
	if ( !looks_like_number($k_expiry) ) {
		$self->field('dnssec.k_expiry')->is_equal( "", "$k_expiry is not a number" );
	}

	return $self->valid;
}

1;