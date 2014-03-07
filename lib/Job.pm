#!/usr/env/perl

=head1 NAME

I<Job>

=head1 SYNOPSIS

Object used to hold information on a Job or Jobs to run

=head1 DESCRIPTION

Object used to hold information on a Job or Jobs to run


=head1 DEPENDENCY

=cut

package Job;

# Strict Pragmas
#--------------------------
use strict;
use warnings;

#--------------------------

# Add the mugqic_pipeline/lib/ path relative to this Perl script to @INC library search variable
use FindBin;
use lib "$FindBin::Bin";

# Dependencies
#-----------------------
use Data::Dumper;
use File::stat;
use List::Util qw(max);
use LoadConfig;

# SUB
#-----------------------
sub new {
  my $class = shift;
  my $self = {
    '_isUp2Date' => 0,
  };
  bless($self, $class);
  return $self;
}

sub addCommand {
  my ($self, $command) = @_;
  if (defined($command)) {
    if (!defined($self->{'_commands'})) {
      $self->{'_commands'} = ();
      $self->{'_commandsJobId'} = ();
    }
    push(@{$self->{'_commands'}}, $command);
  }
}

sub addFilesToTest {
  my ($self, $rA_filesToTest) = @_;
  if (defined($rA_filesToTest)) {
    if (!defined($self->{'_filesToTest'})) {
      $self->{'_filesToTest'} = ();
    }
    push(@{$self->{'_filesToTest'}}, @{$rA_filesToTest});
  }
}

sub getFilesToTest {
  my ($self) = @_;
  return $self->{'_filesToTest'};
}

sub setOutputFileHash {
  my ($self, $rH_outputFiles) = @_;
  $self->{'_outputFiles'} = $rH_outputFiles;
}

sub getOutputFileHash {
  my ($self) = @_;
  return $self->{'_outputFiles'};
}

sub setCommandJobId {
  my ($self, $idx, $jobIdVarName) = @_;
  $self->{'_commandsJobId'}->[$idx] = $jobIdVarName;
}

sub getCommandJobId {
  my ($self, $idx) = @_;
  if (!defined($idx)) {
    $idx = 0;
  }
  return $self->{'_commandsJobId'}->[$idx];
}

sub getCommands {
  my ($self) = @_;
  return $self->{'_commands'};
}

sub getNbCommands {
  my ($self) = @_;
  return scalar(@{$self->{'_commands'}});
}

sub getCommand {
  my ($self, $idx) = @_;
  if (!defined($idx)) {
    $idx = 0;
  }
  return $self->{'_commands'}->[$idx];
}

sub setUp2Date {
  my ($self, $up2date) = @_;
  if (defined($up2date)) {
    $self->{'_isUp2Date'} = $up2date;
  }
  return $self->{'_isUp2Date'};
}

sub isUp2Date {
  my ($self) = @_;
  return $self->{'_isUp2Date'};
}

# Test if job is up to date by checking job output .done presence and comparing input/output file modification times 
# If job is out of date, set job files to test with list of output files
sub testInputOutputs {
  my ($self, $rA_inputs, $rA_outputs) = @_;

  if (!defined($rA_inputs) || !defined($rA_outputs) || scalar(@{$rA_inputs}) == 0 || scalar(@{$rA_outputs}) == 0) {
    # Don't return 'touch' command, but return something so undef tests fail
    return "";
  }

  my $isJobUp2Date = 1;   # Job is up to date by default

  # Retrieve latest input file modification time i.e. maximum stat mtime
  # Use 'echo' system command to expand environment variables in input file paths if any
  # Also check if input file exists before calling mtime function, return 0 otherwise
  my $latestInputTime = max(map(-e `echo -n $_` ? stat(`echo -n $_`)->mtime : 0, @$rA_inputs));

  if ($latestInputTime == 0) {    # i.e. if job input files don't exist yet
    $isJobUp2Date = 0;
  } else {
    for my $outputFile (@$rA_outputs) {

      # Use 'echo' system command to expand environment variables in output file path if any
      my $outputExpandedFile = `echo -n $outputFile`;
  
      # Skip further tests if job is already out of date
      if ($isJobUp2Date) {
        # If .done file is missing or if output file is older than latest input file, job is not up to date
        unless ((-e $outputExpandedFile) and (-e $outputExpandedFile . ".mugqic.done") and (stat($outputExpandedFile)->mtime >= $latestInputTime)) {
          $isJobUp2Date = 0;
        }
      }
    }
  }

  $self->setUp2Date($isJobUp2Date);
  if ($isJobUp2Date) {
    return undef;
  } else {
    my @outputDoneFiles = map("$_.mugqic.done", @$rA_outputs);
    $self->addFilesToTest(\@outputDoneFiles);
    return " && touch " . join(" ", @outputDoneFiles);
  }
}

1;
