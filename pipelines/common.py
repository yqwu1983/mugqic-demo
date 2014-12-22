#!/usr/bin/env python

# Python Standard Modules
import logging
import os
import re
import socket
import sys

# Append mugqic_pipelines directory to Python library path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[0]))))

# MUGQIC Modules
from core.job import *
from core.pipeline import *
from bfx.design import *
from bfx.readset import *

from bfx import metrics
from bfx import picard
from bfx import trimmomatic

log = logging.getLogger(__name__)

# Abstract pipeline gathering common features of all MUGQIC pipelines (readsets, samples, remote log, etc.)
class MUGQICPipeline(Pipeline):

    def __init__(self):
        self.version = open(os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "VERSION"), 'r').read().split('\n')[0]

        # Add pipeline specific arguments
        self.argparser.description = "Version: " + self.version + "\n\nFor more documentation, visit our website: https://bitbucket.org/mugqic/mugqic_pipelines/"
        self.argparser.add_argument("-v", "--version", action="version", version="mugqic_pipelines " + self.version, help="show the version information and exit")

        super(MUGQICPipeline, self).__init__()

    @property
    def readsets(self):
        return self._readsets

    @property
    def samples(self):
        if not hasattr(self, "_samples"):
            self._samples = list(collections.OrderedDict.fromkeys([readset.sample for readset in self.readsets]))
        return self._samples

    def mugqic_log(self):
        server = "http://mugqic.hpc.mcgill.ca/cgi-bin/pipeline.cgi"
        request = \
            "hostname=" + socket.gethostname() + "&" + \
            "ip=" + socket.gethostbyname(socket.gethostname()) + "&" + \
            "pipeline=" + self.__class__.__name__ + "&" + \
            "steps=" + ",".join([step.name for step in self.step_range]) + "&" + \
            "samples=" + str(len(self.samples))

        print("""
{separator_line}
# Call home with pipeline statistics
{separator_line}
wget "{server}?{request}" --quiet --output-document=/dev/null
""".format(separator_line = "#" + "-" * 79, server=server, request=request))


    def submit_jobs(self):
        super(MUGQICPipeline, self).scheduler.submit(self)
        if self.jobs and self.args.job_scheduler in ["pbs", "batch"]:
            self.mugqic_log()


# Abstract pipeline gathering common features of all Illumina sequencing pipelines (trimming, etc.)
# Specific steps must be defined in Illumina children pipelines.
class Illumina(MUGQICPipeline):

    def __init__(self):
        self.argparser.add_argument("-r", "--readsets", help="readset file", type=file)
        super(Illumina, self).__init__()

    @property
    def readsets(self):
        if not hasattr(self, "_readsets"):
            if self.args.readsets:
                self._readsets = parse_illumina_readset_file(self.args.readsets.name)
            else:
                self.argparser.error("argument -r/--readsets is required!")
        return self._readsets

    @property
    def run_type(self):
        run_types = [readset.run_type for readset in self.readsets]
        if len(set(run_types)) == 1 and re.search("^(PAIRED|SINGLE)_END$", run_types[0]):
            return run_types[0]
        else:
            raise Exception("Error: readset run types " + ",".join(["\"" + run_type + "\"" for run_type in run_types]) +
            " are invalid (should be all PAIRED_END or all SINGLE_END)!")

    @property
    def contrasts(self):
        if not hasattr(self, "_contrasts"):
            if self.args.design:
                self._contrasts = parse_design_file(self.args.design.name, self.samples)
            else:
                self.argparser.error("argument -d/--design is required!")
        return self._contrasts

    def picard_sam_to_fastq(self):
        """
        Convert SAM/BAM files from the input readset file into FASTQ format
        if FASTQ files are not already specified in the readset file. Do nothing otherwise.
        """
        jobs = []
        for readset in self.readsets:
            if readset.bam:
                # If readset FASTQ files are available, skip this step
                if not readset.fastq1:
                    if readset.run_type == "PAIRED_END":
                        fastq1 = re.sub("\.bam$", ".pair1.fastq.gz", readset.bam)
                        fastq2 = re.sub("\.bam$", ".pair2.fastq.gz", readset.bam)
                    elif readset.run_type == "SINGLE_END":
                        fastq1 = re.sub("\.bam$", ".single.fastq.gz", readset.bam)
                    else:
                        raise Exception("Error: run type \"" + readset.run_type +
                        "\" is invalid for readset \"" + readset.name + "\" (should be PAIRED_END or SINGLE_END)!")

                    job = picard.sam_to_fastq(readset.bam, fastq1, fastq2)
                    job.name = "picard_sam_to_fastq." + readset.name
                    jobs.append(job)
            else:
                raise Exception("Error: BAM file not available for readset \"" + readset.name + "\"!")
        return jobs

    def trimmomatic(self):
        """
        Raw reads quality trimming and removing of Illumina adapters is performed using [Trimmomatic](http://www.usadellab.org/cms/index.php?page=trimmomatic).

        This step takes as input files:

        1. FASTQ files from the readset file if available
        2. Else, FASTQ output files from previous picard_sam_to_fastq conversion of BAM files
        """
        jobs = []
        for readset in self.readsets:
            trim_directory = os.path.join("trim", readset.sample.name)
            trim_file_prefix = os.path.join(trim_directory, readset.name + ".trim.")
            trim_log = trim_file_prefix + "log"
            trim_stats = trim_file_prefix + "stats.csv"
            if readset.run_type == "PAIRED_END":
                candidate_input_files = [[readset.fastq1, readset.fastq2]]
                if readset.bam:
                    candidate_input_files.append([re.sub("\.bam$", ".pair1.fastq.gz", readset.bam), re.sub("\.bam$", ".pair2.fastq.gz", readset.bam)])
                [fastq1, fastq2] = self.select_input_files(candidate_input_files)
                job = trimmomatic.trimmomatic(
                    fastq1,
                    fastq2,
                    trim_file_prefix + "pair1.fastq.gz",
                    trim_file_prefix + "single1.fastq.gz",
                    trim_file_prefix + "pair2.fastq.gz",
                    trim_file_prefix + "single2.fastq.gz",
                    None,
                    readset.quality_offset,
                    trim_log
                )
            elif readset.run_type == "SINGLE_END":
                candidate_input_files = [[readset.fastq1]]
                if readset.bam:
                    candidate_input_files.append([re.sub("\.bam$", ".single.fastq.gz", readset.bam)])
                [fastq1] = self.select_input_files(candidate_input_files)
                job = trimmomatic.trimmomatic(
                    fastq1,
                    None,
                    None,
                    None,
                    None,
                    None,
                    trim_file_prefix + "single.fastq.gz",
                    readset.quality_offset,
                    trim_log
                )
            else:
                raise Exception("Error: run type \"" + readset.run_type +
                "\" is invalid for readset \"" + readset.name + "\" (should be PAIRED_END or SINGLE_END)!")

            jobs.append(concat_jobs([
                # Trimmomatic does not create output directory by default
                Job(command="mkdir -p " + trim_directory),
                job
            ], name="trimmomatic." + readset.name))
        return jobs

    def merge_trimmomatic_stats(self):
        """
        The trim statistics per readset are merged at this step.
        """
        merge_trim_stats = os.path.join("metrics", "trimming.stats")
        job = concat_jobs([Job(command="rm -f " + merge_trim_stats), Job(command="mkdir -p metrics")])
        for readset in self.readsets:
            trim_log = os.path.join("trim", readset.sample.name, readset.name + ".trim.log")
            if readset.run_type == "PAIRED_END":
                perl_command = "perl -pe 's/^Input Read Pairs: (\d+).*Both Surviving: (\d+).*Forward Only Surviving: (\d+).*$/{readset.sample.name}\t{readset.name}\t\\1\t\\2\t\\3/'".format(readset=readset)
            elif readset.run_type == "SINGLE_END":
                perl_command = "perl -pe 's/^Input Reads: (\d+).*Surviving: (\d+).*$/{readset.sample.name}\t{readset.name}\t\\1\t\\2\t\\2/'".format(readset=readset)

            job = concat_jobs([
                job,
                Job(
                    [trim_log],
                    [merge_trim_stats],
                    command="""\
grep ^Input {trim_log} | \\
{perl_command} \\
  >> {merge_trim_stats}""".format(
                        trim_log=trim_log,
                        perl_command=perl_command,
                        merge_trim_stats=merge_trim_stats
                    )
                )
            ], name="merge_trimmomatic_stats")

        return [job]
