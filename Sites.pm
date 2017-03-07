#   Copyright 2017 Nigel Peck
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

package Sites;

use strict;
use warnings;
use utf8;

use FindBin qw($RealBin);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);
use JSON::Validator qw();
use File::Find qw(find);

use constant SITES_SCHEMA => dirname($RealBin) . "/sites-schema/sites-schema.json";
use constant DEFAULT_CONFIG_DATA_FILE => "/etc/sites/sites.json";

# Attributes
my $class_attributes = {
	config_data_file => 'ro',
	config_data => 'ro'
};

# Attribute defaults
my $class_attribute_defaults = {
	config_data_file => DEFAULT_CONFIG_DATA_FILE
};

# Constructor
sub new {
	my ( $class, $attrs ) = @_;
	$attrs = $attrs || {};
	my $self = bless {
		map {
			$_ => defined $attrs->{$_}
				? $attrs->{$_}
				: $class_attribute_defaults->{$_}
		} keys %$class_attributes
	}, $class;
	_prepare ( $self );
	return $self;
}

# Getter
sub get {
	my ( $self, $attr ) = @_;
	if ( defined $class_attributes->{$attr} && $class_attributes->{$attr} =~ /^(?:ro|rw)$/ ) {
		return $self->{$attr};
	} else {
		die "Attempt to get unknown attribute: $attr"
	}
}

# Setter
sub set {
	my ( $self, $attr, $value ) = @_;
	if ( $class_attributes->{$attr} eq 'rw' ) {
		$self->{$attr} = $value;
	} else {
		die "Attempt to write to non-writable attribute: $attr"
	}
	return $self->{$attr};
}

sub _prepare {
	my $self = shift;
	# Get the config data
	my $sites_json = _slurp_file ( $self->{'config_data_file'} );
	# Parse the config data
	$self->{'config_data'} = decode_json ( $sites_json );
	# Validate the config data
	{
		my $validator = JSON::Validator->new;
		$validator->schema(SITES_SCHEMA);
		my @errors = $validator->validate($self->{'config_data'});
		if ( @errors ) {
			my $error;
			$error .= "$_\n" foreach @errors;
			die "Failed to validate data:\n$error";
		}
	}
}

sub _slurp_file {
	my $file = shift;
	return do {
		open ( my $fh, "<:encoding(UTF-8)", $file )
			or die "Failed to open file: $file";
		local $/;
		<$fh>;
	};
}

'and they all lived happily ever after';
