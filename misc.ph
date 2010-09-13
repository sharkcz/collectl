# copyright, 2003-2009 Hewlett-Packard Development Company, LP

#    M i s c e l l a n e u o s    C o u n t e r

use strict;

# Allow reference to collectl variables, but be CAREFUL as these should be treated as readonly
our ($miniFiller, $rate, $SEP, $datetime, $miniInstances, $interval);

my (%miscNotOpened, $miscUptime, $miscMHz, $miscMounts, $miscLogins);
my ($miscUptimeTOT, $miscMHzTOT, $miscMountsTOT, $miscLoginsTOT);
my ($miscInterval, $miscImportCount, $miscSampleCounter);
sub miscInit
{
  my $impOptsref=shift;
  my $impKeyref= shift;

  # For now, only options are 'i=' and s
  $miscInterval=60;
  if (defined($$impOptsref))
  {
    foreach my $option (split(/,/,$$impOptsref))
    {
      my ($name, $value)=split(/=/, $option);
      error("invalid misc option: '$name'")    if $name ne 'i' && $name ne 's';

      $miscInterval=$value    if $name eq 'i';
    }
  }

  $miscImportCount=int($miscInterval/$interval);
  error("misc interval option not a multiple of '$interval' seconds")
        if $interval*$miscImportCount != $miscInterval;

  $$impOptsref='s';    # only one collectl cares about
  $$impKeyref='misc';

  $miscSampleCounter=-1;
  $miscLogins=0;
}

# Nothing to add to header
sub miscUpdateHeader
{
}

sub miscGetData
{
  return    if ($miscSampleCounter++ % $miscImportCount)!=0;

  getProc(0, '/proc/uptime', 'misc-uptime');
  grepData(1, '/proc/cpuinfo', 'MHz', 'misc-mhz');
  grepData(2, '/proc/mounts', ' nfs ', 'misc-mounts');
  getExec(4, '/usr/bin/who -s -u', 'misc-logins');
}

sub miscInitInterval
{
}

sub miscAnalyze
{
  my $type=   shift;
  my $dataref=shift;

  $type=~/^misc-(.*)/;
  $type=$1;
  my @fields=split(/\s+/, $$dataref);

  if ($type eq 'uptime')
  {
    $miscUptime=$fields[0];
  }
  elsif ($type eq 'mhz')
  {
    $miscMHz=$fields[3];
  }
  elsif ($type eq 'mounts')
  {
    $miscMounts=$fields[0];
  }
  elsif ($type eq 'logins:')  # getExec adds on the ':'
  {
    $miscLogins=$fields[0];
  }
}

sub miscPrintBrief
{
  my $type=shift;
  my $lineref=shift;

  if ($type==1)       # header line 1
  {
    $$lineref.="<------Misc------>";
  }
  elsif ($type==2)    # header line 2
  {
    $$lineref.=" UTim  MHz MT Log ";
  }
  elsif ($type==3)    # data
  {
    $$lineref.=sprintf(" %4s %4d %2d %3d ", 
	cvt($miscUptime/86400), $miscMHz, $miscMounts, $miscLogins);
  }
  elsif ($type==4)    # reset 'total' counters
  {
    $miscUptimeTOT=$miscMHzTOT=$miscMountsTOT=$miscLoginsTOT=0;
  }
  elsif ($type==5)    # increment 'total' counters
  {
    $miscUptimeTOT+=   int($miscUptime/86400+.5);    # otherwise we get round off error
    $miscMHzTOT+=      $miscMHz;
    $miscMountsTOT+=   $miscMounts;
    $miscLoginsTOT+=   $miscLogins;
  }
  elsif ($type==6)    # print 'total' counters
  {
    printf " %4d %4d %2d %3d ", $miscUptimeTOT/$miniInstances, $miscMHzTOT/$miniInstances,
	                        $miscMountsTOT/$miniInstances, $miscLoginsTOT/$miniInstances;
  }
}

sub miscPrintVerbose
{
  my $printHeader=shift;
  my $homeFlag=   shift;
  my $lineref=    shift;

  my $line='';
  if ($printHeader)
  {
    $line.="\n"    if !$homeFlag;
    $line.="# MISC STATISTICS\n";
    $line.="#$miniFiller UpTime  CPU-MHz Mounts Logins\n";
  }
  $$lineref=$line;
  $$lineref.=sprintf("$datetime  %6s   %6d %6d %6d \n", 
	cvt($miscUptime/86400), $miscMHz, $miscMounts, $miscLogins);
}

sub miscPrintPlot
{
  my $type=   shift;
  my $ref1=   shift;

  # Headers
  $$ref1.="[MISC]Uptime${SEP}[MISC]MHz${SEP}[MISC]Mounts${SEP}[MISC]Logins${SEP}"
			if $type==1;

  # Summary Data Only
  $$ref1.=sprintf("$SEP%d$SEP%d$SEP%d$SEP%d",
		$miscUptime/86400, $miscMHz, $miscMounts, $miscLogins)
			if $type==3;
}

sub miscPrintExport
{
  return    if (($miscSampleCounter-1) % $miscImportCount)!=0;

  my $type=   shift;
  my $ref1=   shift;
  my $ref2=   shift;
  my $ref3=   shift;

  if ($type eq 'l')
  {
     push @$ref1, "misc.uptime";   push @$ref2, sprintf("%d", $miscUptime/86400);
     push @$ref1, "misc.cpuMHz";   push @$ref2, sprintf("%d", $miscMHz);
     push @$ref1, "misc.mounts";   push @$ref2, sprintf("%d", $miscMounts);
     push @$ref1, "misc.logins";   push @$ref2, sprintf("%d", $miscLogins);
  }
  elsif ($type eq 's')
  {
    $$ref1.=sprintf("  (misctotals (uptime %d) (cpuMHz %d) (mounts %d) (logins %d))\n",
	$miscUptime/86400, $miscMHz, $miscMounts, $miscLogins);
  }
  elsif ($type eq 'g')
  {
     push @$ref2, 'num', 'num', 'num', 'num', 'num';
     push @$ref1, "misc.uptime";   push @$ref3, sprintf("%d", $miscUptime/86400);
     push @$ref1, "misc.cpuMHz";   push @$ref3, sprintf("%d", $miscMHz);
     push @$ref1, "misc.mounts";   push @$ref3, sprintf("%d", $miscMounts);
     push @$ref1, "misc.logins";   push @$ref3, sprintf("%d", $miscLogins);
  }
}

# Type 1: return contents of first match
# Type 2: return count of all matches
sub grepData
{
  my $type=  shift;
  my $proc=  shift;
  my $string=shift;
  my $tag=   shift;

  # From getProc()
  if (!open PROC, "<$proc")
  {
    # but just report it once, but not foe nfs or proc data
    logmsg("W", "Couldn't open '$proc'")    if !defined($miscNotOpened{$proc});
    $miscNotOpened{$proc}=1;
    return(0);
  }

  my $count=0;
  foreach my $line (<PROC>)
  {
    next    if $line!~/$string/;

    if ($type==1)
    {
      record(2, "$tag $line");
      return;
    }

    $count++;
  }
  record(2, "$tag $count\n");
}

1;
