#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Std;
use Getopt::Long;
use File::Basename;
use Cwd qw[abs_path];
use File::Temp qw[tempfile tempdir];

use lib dirname($0);
use configdata;

my @usage;
push @usage, "Usage: ".basename($0)." [options]\n";
push @usage, "Calculate spanning fragment length pvalue\n";
push @usage, "  -h, --help      Displays this information\n";
push @usage, "  -c, --config    Configuration Filename\n";
push @usage, "  -p, --pan       Spanning Clusters Sam Filename\n";
push @usage, "  -b, --breaks    Breakpoint Predictions Filename\n";
push @usage, "  -s, --seqs      Sequence Predictions Filename\n";
push @usage, "  -r, --rstat     Read Statistics Filename\n";
push @usage, "  -v, --vstat     Covariance Statistics Filename\n";

my $help;
my $config_filename;
my $clusters_filename;
my $breaks_filename;
my $seqs_filename;
my $rstat_filename;
my $vstat_filename;

GetOptions
(
 	'help'        => \$help,
	'config=s'    => \$config_filename,
	'pan=s'       => \$clusters_filename,
 	'breaks=s'    => \$breaks_filename,
	'seqs=s'      => \$seqs_filename,
	'rstat=s'     => \$rstat_filename,
	'vstat=s'     => \$vstat_filename,
);

not defined $help or usage() and exit;

defined $config_filename or die @usage;
defined $clusters_filename or die @usage;
defined $breaks_filename or die @usage;
defined $seqs_filename or die @usage;
defined $rstat_filename or die @usage;
defined $vstat_filename or die @usage;

my $config = configdata->new();
$config->read($config_filename);

my $rscript_bin = $config->get_value("rscript_bin");

my $evaluate_fraglength_rscript = "$rscript_bin ".dirname($0)."/evaluate_fraglength_mean.R";

my %cluster_break_pos;
open BR, $breaks_filename or die "Error: Unable to find $breaks_filename: $!\n";
while (<BR>)
{
	chomp;
	my @fields = split /\t/;
	
	my $cluster_id = $fields[0];
	my $ref_name = $fields[1];
	my $strand = $fields[2];
	my $break_pos = $fields[3];
	
	$cluster_break_pos{$cluster_id}{$ref_name} = $break_pos;
}
close BR;

my %cluster_inter_length;
open SEQ, $seqs_filename or die "Error: Unable to find $seqs_filename: $!\n";
while (<SEQ>)
{
	chomp;
	my @fields = split /\t/;
	
	my $cluster_id = $fields[0];
	my $inter_length = $fields[2];
	
	$cluster_inter_length{$cluster_id} = $inter_length;
}
close SEQ;

my %cluster_strand;
my %cluster_align_start;
my %cluster_align_end;
open SP, $clusters_filename or die "Error: Unable to find $clusters_filename: $!\n";
while (<SP>)
{
	chomp;
	my @fields = split /\t/;
	
	my $cluster_id = $fields[0];
	my $read_id = $fields[1];
	my $flag = $fields[2];
	my $ref_name = $fields[3];
	my $start = $fields[4];
	my $end = $start + length($fields[10]) - 1;

	$read_id =~ /(.*)\/([12])/;
	my $fragment_id = $1;
	my $read_end = $2;

	my $strand;
	if ($flag & hex('0x0010'))
	{
		$strand = "-";
	}
	else
	{
		$strand = "+";
	}

	$cluster_strand{$cluster_id}{$ref_name} = $strand;
	
	$cluster_align_start{$cluster_id}{$fragment_id}{$ref_name} = $start;
	$cluster_align_end{$cluster_id}{$fragment_id}{$ref_name} = $end;
}
close SP;

foreach my $cluster_id (keys %cluster_strand)
{
	die "Error: Did not find 2 reference names for cluster $cluster_id\n" if scalar keys %{$cluster_strand{$cluster_id}} != 2;

	my $spanning_fragment_sum = 0;
	my $spanning_fragment_count = 0;

	foreach my $fragment_id (keys %{$cluster_align_start{$cluster_id}})
	{
		my $fragment_length = 0;
		foreach my $ref_name (keys %{$cluster_align_start{$cluster_id}{$fragment_id}})
		{
			my $strand = $cluster_strand{$cluster_id}{$ref_name};
			if ($strand eq "+")
			{
				$fragment_length += $cluster_break_pos{$cluster_id}{$ref_name} - $cluster_align_start{$cluster_id}{$fragment_id}{$ref_name} + 1;
			}
			else
			{
				$fragment_length += $cluster_align_end{$cluster_id}{$fragment_id}{$ref_name} - $cluster_break_pos{$cluster_id}{$ref_name} + 1;
			}
		}
		$fragment_length += $cluster_inter_length{$cluster_id};

		$spanning_fragment_sum += $fragment_length;
		$spanning_fragment_count++;
	}

	my $spanning_fragment_mean = $spanning_fragment_sum / $spanning_fragment_count;

	my $pval_result_span_length = `$evaluate_fraglength_rscript $rstat_filename $vstat_filename $spanning_fragment_mean $spanning_fragment_count`;
	$pval_result_span_length =~ /\[1\]\s+(.+)/ or die "Error: Unable to interpret pvalue from R\n";
	my $length_average_pvalue = $1;

	print $cluster_id."\t".$spanning_fragment_mean."\t".$length_average_pvalue."\n";
}


