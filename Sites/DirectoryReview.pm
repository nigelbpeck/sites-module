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

sub is_within_a_specials_dir {
	my ( $self, $keep_empty ) = @_;
	$keep_empty =~ m!^/([^/]+)/!;
	return $self->{'config_data'}{'directory_structure'}{'directories'}{$1}{'allow_specials'}
		? 1
		: 0;
}

sub prepare_directory_reports {
	my ( $self ) = @_;
	my $report = '';
	foreach my $site_dir (sort keys %{$self->{'config_data'}{'sites'}}) {
		$report .= prepare_directory_report ( $self, $site_dir );
	}
	return $report;
}

sub lock_down_directories {
	my ( $self ) = @_;
	my $report = '';
	foreach my $site_dir (sort keys %{$self->{'config_data'}{'sites'}}) {
		$report .= lock_down_directory ( $self, $site_dir );
	}
	return $report;
}

sub prepare_directory_report {
	my ( $self, $site_dir ) = @_;
	my $report = '';
	process_site_directory ( $self, $site_dir, {
		missing_optional_dir => sub {
			$report .= "$_[0]: optional directory should be provided but isn't\n";
		},
		unallocated_optional_dir => sub {
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
		keep_empty_deleted => sub {
			$report .= "$_[0]: deleted from \"keep empty\" folder\n";
		},
	});
	return $report;
}

sub lock_down_directory {
	my ( $self, $site_dir ) = @_;
	my $report = '';
	process_site_directory ( $self, $site_dir, {
		missing_optional_dir => sub {
			$report .= "$_[0]: optional directory should be provided but isn't\n";
		},
		unallocated_optional_dir => sub {
			$report .= "$_[0]: optional directory shouldn't be provided but is (no further checking done on it)\n";
		},
		missing_required_dir => sub {
			$report .= "$_[0]: required directory does not exist\n";
		},
		user_error => sub {
			my ( $entity, $username_desc, $uid, $current_uid ) = @_;
			chown $uid, -1, $entity or die "Failed to change user for $entity to $username_desc ($uid)";
			$report .= "$entity: changed owner to $username_desc ($uid, was $current_uid)\n";
		},
		group_error => sub {
			my ( $entity, $group_desc, $gid, $current_gid ) = @_;
			chown -1, $gid, $entity or die "Failed to change group for $entity to $group_desc ($gid)";
			$report .= "$entity: changed group to $group_desc ($gid, was $current_gid)\n";
		},
		mode_error => sub {
			chmod oct("0$_[1]"), $_[0] or die "Failed to change mode for $_[0] to $_[1]";
			$report .= "$_[0]: changed mode to $_[1] (was $_[2])\n";
		},
		unknown_entry => sub {
			$report .= "$_[0]: neither file or directory, and nothing else allowed\n";
		},
		unknown_root_entry => sub {
			$report .= "$_[0]: rogue entry found in site root\n";
		},
		keep_empty_deleted => sub {
			$report .= "$_[0]: deleted from \"keep empty\" folder\n";
		},
	});
	return $report;
}

sub process_site_directory {
	my ( $self, $site_dir, $callbacks ) = @_;
	# Easy access to config
	my $config_data = $self->{'config_data'};
	my $sites_config = $config_data->{'sites'};
	my $directory_structure = $config_data->{'directory_structure'};
	# The site, and site type, we are processing
	my $site_config = $sites_config->{$site_dir};
	my $site_type = $config_data->{'site_types'}{$site_config->{'type'}};
	# Error if the directory is not known
	die "Unknown site directory: $site_dir"
		unless $site_config;
	# Check the callbacks
	die "Callbacks must be provided for this method to operate"
		unless ref $callbacks eq 'HASH';
	# Process callbacks
	{
		my $count = 0;
		foreach ( qw(
			missing_optional_dir
			unallocated_optional_dir
			missing_required_dir
			user_error
			group_error
			mode_error
			unknown_entry
			unknown_root_entry
			keep_empty_deleted
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
	# Check that only (potentially) allowed entries exist in root site folder
	opendir(my $dh, $site_dir) or die "Can't opendir $site_dir: $!";
	while ( readdir($dh) ) {
		&{$callbacks->{'unknown_root_entry'}}("$site_dir/$_")
			unless ( $directory_structure->{'directories'}{$_} or /^(?:\.{1,2})$/ );
	}
	closedir $dh;
	# Process any "keep_empty" directories for the site type
	# Delete any files more than a day old from them
	# Delete any empty directories
	if ( ref $site_type->{'keep_empty'} eq 'ARRAY' ) {
		foreach my $keep_empty ( @{$site_type->{'keep_empty'}} ) {
			# Check that it is within a directory that allows specials
			die ( "$site_dir does not allow_specials for $keep_empty" )
				unless is_within_a_specials_dir ( $self, $keep_empty );
			# Shortcut for processing
			my $keep_empty_dir = "$site_dir$keep_empty";
			# Check carefully before deleting things
			# Must be 3 levels deep
			$keep_empty_dir =~ /^(\/[^\/]+){3,}$/
				or die "Unsafe value found for keep_empty directory: '$keep_empty_dir'; refusing to 'find $keep_empty_dir -mindepth 1 -atime 1 -delete'";
			# Carry out the deletions and report them
			_keep_directory_empty ( $keep_empty_dir, $callbacks );
		}
	}
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
				&{$callbacks->{'unallocated_optional_dir'}}($directory_path);
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
			# Only check ownership for "ownership_only" matches
			} elsif ( $directory_config->{'allow_specials'} and _is_ownership_only ( $site_config, $site_dir, $this_dir ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { do_not_check_mode => 1 } );
			# Open folders for site
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_dir, $site_dir, $site_config->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { d_mode => '0777' } );
			# Open folders for site type
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_dir, $site_dir, $site_type->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config, { d_mode => '0777' } );
			# Everything else
			} else {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_dir, $internal_dir_config );
			}
		}, sub {
			# Files
			my $this_file = shift;
			# Only check ownership for "ownership_only" matches
			if ( $directory_config->{'allow_specials'} and _is_ownership_only ( $site_config, $site_dir, $this_file ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { do_not_check_mode => 1 } );
			# Server files
			# (check these first as they can be in open folders)
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $site_config->{'server_files'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0644', user => '[web_server]', group => '[web_server]' } );
			# Open folders for site
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_file, $site_dir, $site_config->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0666' } );
			# Open folders for site type
			} elsif ( $directory_config->{'allow_specials'} and _containing_folder_is_listed ( $this_file, $site_dir, $site_type->{'open_folders'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0666' } );
			# Read only files for site
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $site_config->{'read_only'} ) ) {
				_check_entity ( $config_data, $callbacks, $site_dir, $this_file, $internal_dir_config, { f_mode => '0444' } );
			# Read only files for site type
			} elsif ( $directory_config->{'allow_specials'} and _file_is_listed ( $this_file, $site_dir, $site_type->{'read_only'} ) ) {
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

sub _keep_directory_empty {
	my ( $directory, $callbacks ) = @_;
	finddepth ( sub {
		# Skip the directory being processed
		return if $File::Find::name eq $directory;
		# Delete empty directories
		if ( -d $File::Find::name ) {
			# rmdir will only remove empty directories
			if ( rmdir ( $File::Find::name ) ) {
				# Report back if the directory was deleted
				&{$callbacks->{'keep_empty_deleted'}}($File::Find::name);
			}
		# Only process files, anything else will be picked up as an unknown later
		} elsif ( -f $File::Find::name ) {
			# Get last accessed time
			my $last_access_time = (stat($File::Find::name))[8];
			# If it's more than 24 hours since the entity was accessed
			if ( $last_access_time < ( time - 60 * 60 * 24 ) ) {
				# Delete it
				unlink $File::Find::name;
				# Report back
				&{$callbacks->{'keep_empty_deleted'}}($File::Find::name);
			}
		}
	}, $directory );
}

sub _is_ownership_only {
	my ( $site_config, $site_dir, $entity ) = @_;
	foreach my $ownership_only ( @{$site_config->{'ownership_only'}} ) {
		# Directory match specified
		if ( $ownership_only =~ m!/$! ) {
			return 1 if
				# Directory match
				$entity =~ m!^$site_dir$ownership_only! or
				# Exact directory match
				"$entity/" =~ m!^$site_dir$ownership_only$!;
		# Exact match specified
		} else {
			return 1 if $entity =~ m!^$site_dir$ownership_only$!;
		}
	}
	return 0;
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
