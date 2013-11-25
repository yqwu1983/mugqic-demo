#!/usr/bin/perl

=head1 NAME

I<deNovoTranscriptomeAssemly>

=head1 SYNOPSIS

deNovoTranscriptomeAssemly.pl B<args> [-f -c -n -s -e]

=head1 DESCRIPTION

B<deNovoTranscriptomeAssemly> Is the main de novo RNA assembly pipeline.

=head1 AUTHORS

B<David Morais> - I<dmorais@cs.bris.ac.uk>

B<Mathieu Bourgey> - I<mbourgey@genomequebec.com>

B<Joel Fillon> - I<joel.fillon@mcgill.ca>

=head1 DEPENDENCY

B<Pod::Usage> Usage and help output.

B<Data::Dumper> Used to debbug

B<Config::Simple> Used to parse config file

B<File::Basename> path parsing

B<Cwd> path parsing



B<The pipeline specific libs should be in a dir called lib/ placed in the same dir this as this script.>

I<Pipeline specific Libs:>

B<GetFastaAlias>

B<MergeFastq>

B<LoadConfig>

B<SampleSheet>

B<BAMtools>

B<SplitFile>

B<Trinity>

B<BLAST>

B<SampleSheet>

B<SequenceDictionaryParser>

B<SubmitToCluster>

B<Trimmomatic>

B<BWA>

B<HtseqCount>

B<DiffExpression>


=head1 Scripts

This pipeline uses a set of scripts. 
You should create a dir called B<script>
and place it in the same dir as the 
pipeline.

B<This is the list of scripts>

AliasFastqMerge.py

create_gtf.sh

fastalength

fastasplit

filter-duplicates-1.0-jar-with-dependencies.jar

generate_BLAST_HQ.sh

getStat.sh

HtSeq_full_matrix.sh

HtSeq_temp_matrix.sh

ParallelBlast.pl

Parallelize

=cut

# Strict Pragmas
#---------------------
use strict;
use warnings;

#---------------------

# Add the mugqic_pipeline/lib/ path relative to this Perl script to @INC library search variable
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Dependencies
#-----------------
use Getopt::Std;
use LoadConfig;
use SampleSheet;
use SubmitToCluster;
use Trinity;

# Globals
#---------------------------------
my @steps = (
  {
    'name'   => 'normalization',
    'loop'   => 'global',
    'parent' => undef
  },
  {
    'name'   => 'trinity',
    'loop'   => 'global',
    'parent' => 'normalization'
  },
  {
    'name'   => 'trinityQC',
    'loop'   => 'global',
    'parent' => 'trinity'
  },
  {
    'name'   => 'blastSplitQuery',
    'loop'   => 'global',
    'parent' => 'trinity'
  },
  {
    'name'   => 'blast',
    'loop'   => 'global',
    'parent' => 'blastSplitQuery'
  },
  {
    'name'   => 'rsemPrepareReference',
    'loop'   => 'global',
    'parent' => 'trinity'
  },
  {
    'name'   => 'rsem',
    'loop'   => 'sample',
    'parent' => 'rsemPrepareReference'
  },
  {
    'name'   => 'edgeR',
    'loop'   => 'global',
    'parent' => 'rsem'
  }
);


main();

# SUB
#-----------------
sub getUsage {
  my $usage = <<END;
Usage: perl $0 -h | -c FILE -s number -e number -n FILE [-w DIR]
  -h  help and usage
  -c  .ini config file
  -s  start step, inclusive
  -e  end step, inclusive
  -n  nanuq sample sheet
  -w  work directory (default current)

Steps:
END

  # List and number step names
  for (my $i = 1; $i <= @steps; $i++) {
    $usage .= $i . "- " . $steps[$i - 1]->{'name'} . "\n";
  }

  return $usage;
}

sub main {
  # Check options
  my %opts;
  getopts('hc:s:e:n:w:', \%opts);

  if (defined($opts{'h'}) ||
     !defined($opts{'c'}) ||
     !defined($opts{'s'}) ||
     !defined($opts{'e'}) ||
     !defined($opts{'n'})) {
    die (getUsage());
  }

  my $configFile = $opts{'c'};
  my $startStep = $opts{'s'};
  my $endStep = $opts{'e'};
  my $nanuqSampleSheet = $opts{'n'};
  my $workDirectory = $opts{'w'};

  # Get config and sample values
  my %cfg = LoadConfig->readConfigFile($configFile);
  my $rHoAoH_sampleInfo = SampleSheet::parseSampleSheetAsHash($nanuqSampleSheet);

  SubmitToCluster::initPipeline($workDirectory);

  for (my $i = $startStep; $i <= $endStep; $i++) {
    my $step = $steps[$i - 1];
    my $stepSubName = "Trinity::" . $step->{'name'};
    my $rS_stepSub = \&$stepSubName;
    $step->{'jobIds'} = ();

    if ($step->{'loop'} eq 'sample') {
      foreach my $sample (keys %$rHoAoH_sampleInfo) {
        my $rO_job = &$rS_stepSub(\%cfg, $workDirectory, $sample);
        submitJob(\%cfg, $step, $sample, $rO_job);
      }
    } else {
      my $rO_job = &$rS_stepSub(\%cfg, $workDirectory);
      submitJob(\%cfg, $step, undef, $rO_job);
    }
  }
}

sub getStepParent {
  my $stepParentName = shift;

  my $stepParent = undef;
  if (defined($stepParentName)) {
    foreach my $step (@steps) {
      if ($step->{'name'} eq $stepParentName) {
        $stepParent = $step;
      }
    }
  }
  return $stepParent;
}

sub submitJob {
  my $rH_cfg = shift;
  my $step = shift;
  my $sample = shift;
  my $rO_job = shift;

  my $stepName = $step->{'name'};
  my $stepLoop = $step->{'loop'};
  my $jobIdPrefix = uc($stepName);
  my $jobIds = $jobIdPrefix . "_JOB_IDS";
  if (defined $sample) {
    $jobIdPrefix .= "_" . $sample;
  }

  my $dependencies = "";

  my $stepParentName = $step->{'parent'};
  my $stepParent = getStepParent($stepParentName);
  if (defined($stepParent)) {
    $dependencies = join (":", map {"\$" . $_} @{$stepParent->{'jobIds'}});
  }

  my $jobId = SubmitToCluster::printSubmitCmd($rH_cfg, $stepName, undef, $jobIdPrefix, $dependencies, $sample, $rO_job);

  push (@{$step->{'jobIds'}}, $jobId);
}
