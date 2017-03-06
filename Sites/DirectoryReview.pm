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

package Sites::DirectoryReview;

use strict;
use warnings;
use utf8;

use File::Find qw(finddepth);

# Subclass of Sites
use parent 'Sites';

sub is_valid_site_dir {
	my ( $self, $site_dir ) = @_;
	return defined $self->{'config_data'}{'sites'}{$site_dir};
}

sub prepare_directory_reports {
	my ( $self ) = @_;
	my $report = '';
	foreach my $site_dir (sort keys %{$self->{'config_data'}{'sites'}}) {
		$report .= prepare_directory_report ( $self, $site_dir );
	}
	return $report;
}

sub prepare_directory_report {
	my ( $self, $site_dir ) = @_;
	my $report;
	process_site_directory ( $self, $site_dir, {
		missing_optional_dir => sub {
			$report .= "$_[0]: optional directory should be provided but isn't\n";
		},
		unspecified_optional_dir => sub {
			$report .= "$_[0]: optional directory shouldn't be provided but is (no further checking done on it)\n";
		},
		missing_required_dir => sub {
			$report .= "$_[0]: required directory does not exist\n";
		},
		user_error => sub {
			$report .= "$_[0]: not owned by $_[1] ($_[2] -> $_[3])\n";
		},
		group_error => sub {
			$report .= "$_[0]: group not set to $_[1] ($_[2] -> $_[3])\n";
		},
		mode_error => sub {
			$report .= "$_[0]: mode is not $_[1] ($_[2])\n";
		},
		unknown_entry => sub {
			$report .= "$_[0]: neither file or directory, and nothing else allowed\n";
		},
		unknown_root_entry => sub {
			$report .= "$_[0]: rogue entry found in site root\n";
		},
	});
	return $report;
}

sub take_actions {
	my ( $self ) = @_;
	
}

sub process_site_directory {
	my ( $self, $site_dir, $callbacks ) = @_;
	# Check the callbacks
	die "Callbacks must be provided for this method to operate"
		unless ref $callbacks eq 'HASH';
	# Process callbacks
	{
		my $count = 0;
		foreach ( qw(
			missing_optional_dir
			unspecified_optional_dir
			missing_required_dir
			user_error
			group_error
			mode_error
			unknown_entry
			unknown_root_entry
		) ) {
			if ( ref $callbacks->{$_} eq 'CODE' ) {
				# Keep a count of provided callbacks
				$count++;
			} else {
				# Fill out any empty callbacks
				$callbacks->{$_} = sub{}
			}
		};
		# Error if no callbacks were provided
		die "No callbacks provided, this method needs callbacks to operate"
			unless $count;
	}
	# Easy access to config
	my $config_data = $self->{'config_data'};
	my $sites_config = $config_data->{'sites'};
	my $directory_structure = $config_data->{'directory_structure'};
	# The site we are processing
	my $site_config = $sites_config->{$site_dir};
	# Check that only (potentially) allowed entries exist in root site folder
	opendir(my $dh, $site_dir) or die "Can't opendir $site_dir: $!";
	while ( readdir($dh) ) {
		&{$callbacks->{'unknown_root_entry'}}("$site_dir/$_")
			unless ( $directory_structure->{'directories'}{$_} or /^(?:\.{1,2})$/ );
	}
	closedir $dh;
	# Get root dir config
	my $root_dir_config = {
		d_mode => $directory_structure->{'d_mode'},
		f_mode => $directory_structure->{'f_mode'},
		user => $directory_structure->{'user'},
		group => $directory_structure->{'group'},
	};
	# Check root folder
	_check_entity ( $config_data, $callbacks, $site_dir, $site_dir, $root_dir_config );
	# Check each directory
	foreach my $directory ( sort keys %{$directory_structure->{'directories'}} ) {
		my $directory_path = "$site_dir/$directory";
		# Check the status of the directory
		# Review optional directories
		if ( $directory_structure->{'directories'}{$directory}{'optional'} ) {
			my $provided;
			{
				# Get the optional settings
				my $option = $directory_structure->{'directories'}{$directory}{'optional'};
				my $option_default = $directory_structure->{'directories'}{$directory}{'optional_default'};
				# If the optional setting it provided, use that
				if ( defined $site_config->{'options'}{$option} ) {
					$provided = $site_config->{'options'}{$option};
				# Otherwise use the default
				} elsif ( defined $option_default ) {
					$provided = $option_default;
				# Or error
				} else {
					die "$site_dir: unable to process '$option' option for $directory";
				}
			}
			# Check the status of the optional directory is valid
			if ( $provided and not -d $directory_path ) {
				&{$callbacks->{'missing_optional_dir'}}($directory_path);
				next;
			} elsif ( not $provided and -d $directory_path ) {
				&{$callbacks->{'unspecified_optional_dir'}}($directory_path);
				next;
			# If not provided, go to next directory
			} elsif ( not $provided ) {
				next;
			}
		# Review required directories
		} elsif ( not -d $directory_path ) {
			&{$callbacks->{'missing_required_dir'}}($directory_path);
			next;
		}
		# Shorthand for the directory's config
		my $directory_config = $directory_structure->{'directories'}{$directory};
		# Work out the user/permissions for the directory
		my ( $top_level_dir_config, $internal_dir_config );
		{
			my $this_dir_contents_config = $directory_structure->{'directories'}{$directory}{'contents'}
				? $directory_structure->{'directories'}{$directory}{'contents'}
				: {};
			# For top level directories, if specified, use that
			# otherwise default to the root site folder settings
			$top_level_dir_config = {
				d_mode => $directory_config->{'d_mode'}
					? $directory_config->{'d_mode'}
					: $root_dir_config->{'d_mode'},
				f_mode => $directory_config->{'f_mode'}
					? $directory_config->{'f_mode'}
					: $root_dir_config->{'f_mode'},
				user => $directory_config->{'user'}
					? $directory_config->{'user'}
					: $root_dir_config->{'user'},
				group => $directory_config->{'group'}
					? $directory_config->{'group'}
					: $root_dir_config->{'group'},
			};
			# For internal directories, if specified directly, use that
			# otherwise use the top level directory setting above
			$internal_dir_config = {
				d_mode => $this_dir_contents_config->{'d_mode'}
					? $this_dir_contents_config->{'d_mode'}
					: $top_level_dir_config->{'d_mode'},
				f_mode => $this_dir_contents_config->{'f_mode'}
					? $this_dir_contents_config->{'f_mode'}
					: $top_level_dir_config->{'f_mode'},
				user => $this_dir_contents_config->{'user'}
					? $this_dir_contents_config->{'user'}
					: $top_level_dir_config->{'user'},
				group => $this_dir_contents_config->{'group'}
					? $this_dir_contents_config->{'group'}
					: $top_level_dir_config->{'group'}
				};
		}
		# Check the entire directory
		_check_folder ( $directory_path, $callbacks, sub {
			# Directories
			my $this_dir = shift;
			# Check the top level directory
			if ( $this_dir eq $directory_path ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $top_level_dir_config );
			# Within the .git directory, check ownership only
			} elsif ( $directory_config->{'allow_specials'} and $this_dir =~ m!^$directory_path/\.git(?:$|/)! ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { do_not_check_mode => 1 } );
			# Open folders for site
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_dir, $site_dir, $site_config->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { d_mode => '0777' } );
			# Open folders for site type
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_dir, $site_dir, $config_data->{'site_types'}{$site_config->{'type'}}{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { d_mode => '0777' } );
			# Everything else
			} else {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config );
			}
		}, sub {
			# Files
			my $this_file = shift;
			# Within the .git directory, check ownership only
			if ( $directory_config->{'allow_specials'} and $this_file =~ m!^$directory_path/\.git(?:$|/)! ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { do_not_check_mode => 1 } );
			# Server files
			# (check these first as they can be in open folders)
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $site_config->{'server_files'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0644', user => '[web_server]', group => '[web_server]' } );
			# Open folders for site
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_file, $site_dir, $site_config->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0666' } );
			# Open folders for site type
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_file, $site_dir, $config_data->{'site_types'}{$site_config->{'type'}}{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0666' } );
			# Read only files for site
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $site_config->{'read_only'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0444' } );
			# Read only files for site type
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $config_data->{'site_types'}{$site_config->{'type'}}{'read_only'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0444' } );
			# Everything else
			} else {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config );
			}
		});
	}
}

# Take callbacks to recursively process all files and directories
# in a directory. Error if anything else is found.
sub _check_folder {
	my ( $folder, $callbacks, $sub_directories, $sub_files ) = @_;
	finddepth ( sub {
		if ( -d $File::Find::name ) {
			&$sub_directories ( $File::Find::name );
		} elsif ( -f $File::Find::name ) {
			&$sub_files ( $File::Find::name );
		} else {
			&{$callbacks->{'unknown_entry'}}($File::Find::name);
		}
	}, $folder );
}

sub _check_entity {
	my ( $config_data, $callbacks, $site, $entity, $dir_config, $options ) = @_;
	$options = $options || {};
	# Get ready, we're hitting the town
	my $sites_config = $config_data->{'sites'};
	my ( $check_mode, $check_uid, $check_gid, $username_for_error, $group_for_error );
	# Make sure this is a file or a directory
	if ( not -d $entity and not -f $entity ) {
		&{$callbacks->{'unknown_entry'}}($entity);
		return;
	}
	# Get the mode to check, unless mode checking is disabled
	unless ( $options->{'do_not_check_mode'} ) {
		# Get the mode for the type of entity we're looking at
		if ( -d $entity ) {
			$check_mode = $options->{'d_mode'}
				? $options->{'d_mode'}
				: $dir_config->{'d_mode'};
		} elsif ( -f $entity ) {
			$check_mode = $options->{'f_mode'}
				? $options->{'f_mode'}
				: $dir_config->{'f_mode'};
		}
		# Check the mode is valid
		if ( $check_mode ) {
			$check_mode =~ /^[0-7]{4}$/
				or die "$entity: failed to validate check mode '$check_mode'";
		}
	}
	# Retrieve the user value and convert to a uid
	{
		my $user = $options->{'user'}
			? $options->{'user'}
			: $dir_config->{'user'};
		if ( $user eq '[user]' ) {
			$check_uid = _get_uid($sites_config->{$site}{'user'});
			$username_for_error = $sites_config->{$site}{'user'};
		} elsif ( $user eq '[web_server]' ) {
			$check_uid = _get_uid($config_data->{'web_server'}{'user'});
			$username_for_error = $config_data->{'web_server'}{'user'};
		} else {
			$check_uid = _get_uid ( $user );
			$username_for_error = $user;
		}
	}
	# Retrieve the group value and convert to a gid
	{
		my $group = $options->{'group'}
			? $options->{'group'}
			: $dir_config->{'group'};
		if ( $group eq '[user_primary]' ) {
			$check_gid = _get_primary_gid($sites_config->{$site}{'user'});
			$group_for_error = "primary for $sites_config->{$site}{'user'}";
		} elsif ( $group eq '[root_primary]' ) {
			$check_gid = _get_primary_gid('root');
			$group_for_error = "primary for root";
		} elsif ( $group eq '[web_server]' ) {
			$check_gid = _get_gid($config_data->{'web_server'}{'group'});
			$group_for_error = $config_data->{'web_server'}{'group'};
		} else {
			$check_gid = _get_gid ( $group );
			$group_for_error = $group;
		}
	}
	# Perform the check
	my @stat = stat($entity);
	my ( $mode, $uid, $gid ) = ( $stat[2], $stat[4], $stat[5] );
	# Only check mode if enabled
	unless ( $options->{'do_not_check_mode'} ) {
		$mode = sprintf '%04o', $mode & 07777;
		if ( $mode ne $check_mode ) {
			&{$callbacks->{'mode_error'}}($entity, $check_mode, $mode);
		}
	}
	# Check the uid
	if ( $uid != $check_uid ) {
		&{$callbacks->{'user_error'}}($entity, $username_for_error, $check_uid, $uid);
	}
	# Check the gid
	if ( $gid != $check_gid ) {
		&{$callbacks->{'group_error'}}($entity, $group_for_error, $check_gid, $gid);
	}
}

{
	my $uid_cache = {};
	sub _get_uid {
		my $username = shift;
		return $uid_cache->{$username}
			if $uid_cache->{$username};
		my $uid = getpwnam($username);
		defined $uid or die "Couldn't get uid for '$username'";
		$uid_cache->{$username} = $uid;
		return $uid;
	}
}

{
	my $gid_cache = {};
	sub _get_gid {
		my $groupname = shift;
		return $gid_cache->{$groupname}
			if $gid_cache->{$groupname};
		my $gid = getgrnam($groupname);
		defined $gid or die "Couldn't get gid for '$groupname'";
		$gid_cache->{$groupname} = $gid;
		return $gid;
	}
}

{
	my $primary_gid_cache = {};
	sub _get_primary_gid {
		my $username = shift;
		return $primary_gid_cache->{$username}
			if $primary_gid_cache->{$username};
		my $gid = (getpwnam($username))[3];
		defined $gid or die "Couldn't get primary gid for user '$username'";
		$primary_gid_cache->{$username} = $gid;
		return $gid;
	}
}

sub _containing_folder_is_listed {
	my ( $entity, $root_folder, $list_to_check ) = @_;
	foreach ( @$list_to_check ) {
		return 1 if $entity =~ m!^${root_folder}$_(?:/|$)!;
	}
	return 0;
}

sub _file_is_listed {	  
	my ( $file, $root_folder, $list_to_check ) = @_;
	foreach ( @$list_to_check ) {
		return 1 if $file eq "${root_folder}$_";
	}
	return 0;
}

'and they all lived happily ever after';
