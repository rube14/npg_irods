package WTSI::NPG::HTS::ONT::GridIONRunAuditor;

use namespace::autoclean;

use Carp;
use Data::Dump qw[pp];
use English qw[-no_match_vars];
use File::Basename;
use File::Spec::Functions qw[abs2rel catdir catfile rel2abs splitdir];
use File::Temp;
use IO::Compress::Bzip2 qw[bzip2 $Bzip2Error];
use Moose;
use MooseX::StrictConstructor;
use Sys::Hostname;
use Try::Tiny;

use WTSI::NPG::HTS::ONT::GridIONRun;
use WTSI::NPG::HTS::Metadata;
use WTSI::NPG::HTS::TarManifest;
use WTSI::NPG::iRODS::DataObject;
use WTSI::NPG::iRODS;

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::HTS::ChecksumCalculator
       ];

our $VERSION = '';

## no critic (ValuesAndExpressions::ProhibitMagicNumbers)
our $INFO_COUNT_INTERVAL = 10_000;
## use critic

# These methods are autodelegated to gridion_run
our @HANDLED_RUN_METHODS = qw[device_id
                              experiment_name
                              gridion_name
                              has_device_id
                              has_experiment_name
                              has_gridion_name
                              has_output_dir
                              output_dir
                              source_dir];

has 'dest_collection' =>
  (isa           => 'Str',
   is            => 'ro',
   required      => 1,
   documentation => 'The destination collection within iRODS to store data');

has 'gridion_run' =>
  (isa           => 'WTSI::NPG::HTS::ONT::GridIONRun',
   is            => 'ro',
   required      => 1,
   handles       => [@HANDLED_RUN_METHODS],
   documentation => 'The GridION run');

has 'irods' =>
  (isa           => 'WTSI::NPG::iRODS',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_irods',
   documentation => 'An iRODS handle to run searches and perform updates');

has 'f5_manifests' =>
  (isa           => 'ArrayRef[WTSI::NPG::HTS::TarManifest]',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_f5_manifests',
   documentation => 'The manifests describing tar files sent to iRODS');

has 'fq_manifests' =>
  (isa           => 'ArrayRef[WTSI::NPG::HTS::TarManifest]',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   builder       => '_build_fq_manifests',
   documentation => 'The manifests describing tar files sent to iRODS');

has 'num_replicates' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 1,
   default       => 2,
   documentation => 'The minimum number of valid replicates expected for a ' .
                    'file in iRODS');

around BUILDARGS => sub {
  my ($orig, $class, @args) = @_;

  if (not ref $args[0]) {
    my %args = @args;

    my $run = WTSI::NPG::HTS::ONT::GridIONRun->new
      (gridion_name => delete $args{gridion_name},
       output_dir   => delete $args{output_dir},
       source_dir   => delete $args{source_dir});

    return $class->$orig(gridion_run => $run, %args);
  }
  else {
    return $class->$orig(@args);
  }
};

sub BUILD {
  my ($self) = @_;

  -e $self->source_dir or
    $self->logconfess(sprintf q[Data directory '%s' does not exist],
                      $self->source_dir);
  -d $self->source_dir or
    $self->logconfess(sprintf q[Data directory '%s' is not a directory],
                      $self->source_dir);

  my ($device_id, $experiment_name, @rest) =
    reverse grep { length } splitdir($self->source_dir);
  $self->experiment_name($experiment_name);
  $self->device_id($device_id);

  $self->debug("Using experiment name '$experiment_name' and ",
               "device ID '$device_id'");
  return;
}

=head2 check_all_files

  Arg [1]    : None

  Example    : my ($num_files, $num_processed, $num_errors) =
                 $obj->check_all_files
  Description: Check GridION run directory against the run data stored in
               iRODS.
  Returntype : Array[Int]

=cut

sub check_all_files {
  my ($self) = @_;

  my ($num_files, $num_present, $num_errors) = (0, 0, 0);

  foreach my $result ([$self->check_seq_cfg_files],
                      [$self->check_seq_summary_files],
                      [$self->check_manifest_files],
                      [$self->check_f5_tar_files],
                      [$self->check_fq_tar_files],
                      [$self->check_f5_files],
                      [$self->check_fq_files]) {
    my ($nf, $np, $ne) = @{$result};
    $num_files   += $nf;
    $num_present += $np;
    $num_errors  += $ne;
  }

  return ($num_files, $num_present, $num_errors);
}

sub check_f5_tar_files {
  my ($self) = @_;

  return $self->_check_tar_files($self->f5_manifests);
}

sub check_fq_tar_files {
  my ($self) = @_;

  return $self->_check_tar_files($self->fq_manifests);
}

sub check_f5_files {
  my ($self) = @_;

  my $local_files = $self->gridion_run->list_f5_files;

  return $self->_check_manifest_entries($self->f5_manifests, $local_files);
}

sub check_fq_files {
  my ($self) = @_;

  my $local_files = $self->gridion_run->list_fq_files;

  return $self->_check_manifest_entries($self->fq_manifests, $local_files);
}

sub check_manifest_files {
  my ($self) = @_;

  my $paths = $self->gridion_run->list_manifest_files;

  return $self->_check_ancillary_files($paths);
}

sub check_seq_summary_files {
  my ($self) = @_;

  my $paths = $self->gridion_run->list_seq_summary_files;

  return $self->_check_ancillary_files($paths);
}

sub check_seq_cfg_files {
  my ($self) = @_;

  my $paths = $self->gridion_run->list_seq_cfg_files;

  return $self->_check_ancillary_files($paths);
}

sub read_manifest {
  my ($self, $manifest_path) = @_;

  my $manifest = WTSI::NPG::HTS::TarManifest->new
    (manifest_path => $manifest_path);
  $manifest->read_file;

  return $manifest;
}

sub run_collection {
  my ($self) = @_;

  return catdir($self->dest_collection, $self->gridion_name,
                $self->experiment_name, $self->device_id);
}

sub _check_ancillary_files {
  my ($self, $local_paths) = @_;

  my ($num_files, $num_present, $num_errors) = (0, 0, 0);
  my $collection = $self->run_collection;

 PATH: foreach my $local_path (@{$local_paths}) {
    try {
      $self->debug("Checking for '$local_path' in '$collection'");
      $num_files++;

      my $filename = fileparse($local_path);
      my $obj = WTSI::NPG::iRODS::DataObject->new(collection  => $collection,
                                                  data_object => $filename,
                                                  irods       => $self->irods);
      my $obj_path = $obj->str;

      if ($obj->is_present) {
        $num_present++;
        $self->info("'$local_path' is present in iRODS at '$obj_path'");
      }
      else {
        croak "'$local_path' missing from iRODS at '$obj_path']";
      }

      $self->_check_irods_checksum($local_path, $obj);

      my $num_replicates = scalar $obj->valid_replicates;
      if ($num_replicates >= $self->num_replicates) {
        $self->info("'$obj_path' has $num_replicates ",
                    'valid replicates in iRODS');
      }
      else {
        croak "'$obj_path' has only $num_replicates valid replicates in iRODS";
      }
    } catch {
      $self->error($_);
      $num_errors++;
    };
  }

  return ($num_files, $num_present, $num_errors);
}

sub _check_manifest_tar_files {
  my ($self, $manifest) = @_;

  my ($num_files, $num_present, $num_errors) = (0, 0, 0);

  foreach my $tar_path ($manifest->tar_paths) {
    try {
      $self->debug("Checking for '$tar_path'");
      $num_files++;

      my $obj = WTSI::NPG::iRODS::DataObject->new($self->irods, $tar_path);
      my $obj_path = $obj->str;

      if ($obj->is_present) {
        $num_present++;
        $self->info("'$tar_path' is present in iRODS at '$obj_path'");
      }
      else {
        croak "'$tar_path' missing from iRODS at '$obj_path'";
      }

      my $experiment_name = $self->experiment_name;
      if ($obj->find_in_metadata($EXPERIMENT_NAME, $experiment_name)) {
        $self->info("'$obj_path' has $EXPERIMENT_NAME metadata ",
                    "'$experiment_name'");
      }
      else {
        $self->error("'$obj_path' is missing $EXPERIMENT_NAME ",
                     "metadata '$experiment_name'");
        $num_errors++;
      }

      my $device_id  = $self->device_id;
      if ($obj->find_in_metadata($GRIDION_DEVICE_ID, $device_id)) {
        $self->info("'$obj_path' has $GRIDION_DEVICE_ID ",
                    "metadata '$device_id'");
      }
      else {
        $self->error("'$obj_path' is missing $GRIDION_DEVICE_ID ",
                     "metadata '$device_id'");
        $num_errors++;
      }
    } catch {
      $self->error($_);
      $num_errors++;
    };
  }

  return ($num_files, $num_present, $num_errors);
}

sub _check_tar_files {
  my ($self, $manifests) = @_;

  my ($num_files, $num_present, $num_errors) = (0, 0, 0);

  foreach my $manifest (@{$manifests}) {
    my ($nf, $np, $ne)= $self->_check_manifest_tar_files($manifest);
    $self->info("Checked [ $np / $nf ] files with $ne errors");
    $num_files   += $nf;
    $num_present += $np;
    $num_errors  += $ne;
  };

  return ($num_files, $num_present, $num_errors);
}

sub _check_manifest_entries {
  my ($self, $manifests, $local_paths) = @_;

  my @manifest_paths = map { $_->manifest_path } @{$manifests};
  $self->debug('Checking content of manifests ', pp(\@manifest_paths));

  my ($num_files, $num_present, $num_errors) = (0, 0, 0);

  my $tmpdir = File::Temp->newdir('GridIONRunAuditor.' . $PID . '.XXXXXXXXX',
                                  DIR     => '/tmp',
                                  CLEANUP => 1);
  $num_files = scalar @{$local_paths};

  my $i = 0;
  foreach my $local_path (@{$local_paths}) {
    try {
      $i++;

      # In earlier runs, tar files are created relative to the device
      # directory containing the run output i.e. the directory
      # containing the sequencing_summary_*.txt and fastq files.
      #
      # In later runs, tar files are created relative to the parent of
      # the experiment directory, two levels up from the device
      # directory. This change allows the experiment_name and
      # device_id to be captured in the path of the tarred files.
      #
      # We need to check both options here.
      my $short_item_path = abs2rel($local_path, $self->source_dir);
      my $long_item_path  = catdir($self->experiment_name, $self->device_id,
                                   $short_item_path);
      my $checksum = $self->calculate_checksum($local_path);

      my $found_manifest;
      my $found_path;

    MANIFEST: foreach my $manifest (@{$manifests}) {
        foreach my $item_path ($long_item_path, $short_item_path) {
          my $compressed_path = "$item_path.bz2";
          $self->debug("Checking for item '$compressed_path'");

          if ($manifest->contains_item($compressed_path)) {
            my $mpath = $manifest->manifest_path;
            my $item_checksum = $manifest->get_item($compressed_path)->checksum;
            $self->debug("Checking manifest '$mpath' '$compressed_path' has ",
                         "checksum '$item_checksum' and expected ",
                         "checksum '$checksum'");

            if ($item_checksum eq $checksum) {
              $found_manifest = $manifest;
              $found_path     = $item_path;
              last MANIFEST;
            }
          }
        } # foreach long and short
      } # foreach manifest

      if ($i % $INFO_COUNT_INTERVAL == 0) {
        $self->info("Checked [ $i / $num_files ] manifest entries");
      }

      if ($found_path) {
        $num_present++;
        $self->debug("$found_path with checksum '$checksum' ",
                     'is present in manifest ', $found_manifest->manifest_path);
      }
      else {
        croak "$long_item_path with checksum '$checksum' " .
          'is missing from the manifests';
      }
    } catch {
      $num_errors++;
      $self->error($_);
    };
  }

  $self->info("Checked [ $i / $num_files ] manifest entries");

  return ($num_files, $num_present, $num_errors);
}

sub _check_irods_checksum {
  my ($self, $local_path, $obj) = @_;

  my $obj_path     = $obj->str;
  my $obj_checksum = $obj->checksum;
  if ($obj->validate_checksum_metadata) {
    $self->info("'$obj_path' has valid checksum metadata in iRODS");
  }
  else {
    croak "'$obj_path' has invalid checksum metadata in iRODS";
  }

  my $checksum = $self->calculate_checksum($local_path);
  if ($obj_checksum eq $checksum) {
    $self->info("Checksum '$checksum' of '$local_path' matches ",
                "checksum of '$obj_path' in iRODS");
  }
  else {
    croak "Checksum '$checksum' of '$local_path' does not match " .
      "checksum of '$obj_path' '$obj_checksum' in iRODS";
  }

  return;
}

sub _build_irods {
  my ($self) = @_;

  return WTSI::NPG::iRODS->new;
}

sub _build_f5_manifests {
  my ($self) = @_;

  my @manifests;
  foreach my $path (@{$self->gridion_run->list_f5_manifest_files}) {
    push @manifests, $self->read_manifest($path);
  }

  return \@manifests;
}

sub _build_fq_manifests {
  my ($self) = @_;

  my @manifests;
  foreach my $path (@{$self->gridion_run->list_fq_manifest_files}) {
    push @manifests, $self->read_manifest($path);
  }

  return \@manifests;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::ONT::GridIONRunAuditor

=head1 DESCRIPTION

Checks that the files of a single GridION run (the results of a single
flowcell) are in iRODS by comparing the contents of the local run
directory with the contents of the iRODS collection into which the
data were published.

The following are checked:

 - Local configuration.cfg files are in iRODS.
 - Local sequencing_summary_n.txt files are in iRODS.
 - Local tar manifest files are in iRODS.
 - Local fastq files are mapped to tar files in iRODS by a tar manifest.
 - Tar files described in tar manifests are in iRODS.

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2017, 2018 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
