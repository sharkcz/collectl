# copyright, 2003-2009 Hewlett-Packard Development Company, LP

# NOTE - this module will build the global %virtMacs like this:
#   $virtMacs{macaddr}=vnetname, where the macaddr is the rightmost 5 octets of the address
#
# RESTRICTIONS
# - if run with -sZ, this will collectl vnet info every interval2; otherwise interval1

use strict;

our ($subsys, $counted2, $limit2);

my $VNET;
our %virtMacs;
my $interval2Flag;
my $dirname="/sys/devices/virtual/net";

sub vnetInit
{
  my $impOptsref=shift;
  my $impKeyref= shift;

  $interval2Flag=($subsys=~/Z/) ? 1 : 0;

  opendir ($VNET, "$dirname") or logmsg('F', "Couldn't open '$dirname' for reading");

  $$impOptsref='s';    # only one collectl cares about
  $$impKeyref='vnet';

  return(1);
}

# Nothing to add to header
sub vnetUpdateHeader
{ }

sub vnetGetData
{
  # read network data every interval unless we're also doing process data, then only then
  if (!$interval2Flag || $counted2==$limit2)
  {
    my $vnets='';
    seekdir($VNET, 0);
    while (my $vnet=readdir($VNET))
    {
      next    if $vnet!~/^tap/;

      my $filename="$dirname/$vnet/address";
      open FILE, "<$filename" or die "DIE: $filename";
      my $mac=<FILE>;
      chomp $mac;
      close FILE;
      $vnets.="$vnet=$mac ";
    }
    $vnets=~s/ $//;
    record(2, "vnets $vnets\n")    if $vnets ne '';
  }
}

sub vnetInitInterval
{ }

sub vnetAnalyze
{
  my $type=   shift;
  my $dataref=shift;

  foreach my $vnet (split(/\s+/, $$dataref))
  {
    my ($netname, $mac)=split(/=/, $vnet);
    $mac=~s/^.{3}//;
    $virtMacs{$mac}=$netname;
    #print "virtMacs{$mac}=$netname\n";
  }
}

sub vnetPrintBrief
{ }

sub vnetPrintVerbose
{ }

sub vnetPrintPlot
{ }

sub vnetPrintExport
{ }

1;
