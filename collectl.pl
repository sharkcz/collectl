#!/usr/bin/perl -w

# Copyright 2003-2007 Hewlett-Packard Development Company, L.P. 
#
# collectl may be copied only under the terms of either the Artistic License
# or the GNU General Public License, which may be found in the source kit

# debug
#    1 - print interesting stuff
#    2 - print more details, currently only lustre/IB service checks
#    4 - show each line processed by record(), replaces -H
#    8 - do NOT remove error file after execution of shell commands
#   16 - print headers of each file processed
#   32 - skip call to dataAnalyze during interactive processing
#   64 - print raw data as processed in playback mode, with timestamps
#  128 - show collectl.conf processing
#  256 - show detailed pid processing (this generates a LOT of output)
#  512 - show more pid details, specificall hash contents
#        NOTE - output from 256/512 are prefaced with %%% if from collectl.pl
#               and ### if from formatit.ph
# 1024 - show list of SLABS to be monitored
# 2048 - playback preprocessing analysis
# 4096 - display config header (to be turned into a switch in newer version)
# 8192 - show creation of RAW, PLOT and SEXPR files

# debug tricks
# - use '-d36' to see each line of raw data as it would be logged but not 
#   generate any other output

# Equivalent Utilities
#  -s c      mpstat, iostat -c, vmstat
#  -s C      mpstat
#  -s d/D    iostat -d
#  -s f/F    nfsstat -c/s [c if -o C]
#  -s i      sar -v
#  -s m      sar -rB, free, vmstat (note - sar does pages by pagesizsie NOT bytes)
#  -s n/N    netstat -i
#  -s p/P    iostat -x
#  -s s      sar -n SOCK
#  -s y/Y    slabtop
#  -s Z      ps or top

# Subsystems
#  c - cpu
#  d - disks
#  E - environmental
#  i - inodes (and other file stuff)
#  f - NFS
#  l - lustre
#  m - memory
#  n - network
#  s - socket
#  t - tcp
#  x - interconnect
#  Z - processes (-sP now available but -P taken!)

use POSIX;
use Config;
use Getopt::Long;
Getopt::Long::Configure ("bundling");
Getopt::Long::Configure ("no_ignore_case");
Getopt::Long::Configure ("pass_through");
use File::Basename;
use Time::Local;
use IO::Socket;
use IO::Select;

# Constants and removing -w warnings
$miniDateFlag=0;
$kernel2_4=$kernel2_6=$PageSize=0;
$PidFile='/var/run/collectl.pid';
$PerlVers=$Memory=$Swap=$Hyper='';
$CpuVendor=$CpuMHz=$CpuCores=$CpuSiblings='';
$PQuery=$PCounter=$VStat=$VoltaireStats=$IBVersion=$HCALids='';
$numBrwBuckets=$cfsVersion=$sfsVersion='';

# Find out ASAP if we're linux or WNT based as well as whether or not XC based
$PcFlag=($Config{"osname"}=~/MSWin32/) ? 1 : 0;
$XCFlag=(!$PcFlag && -e '/etc/hptc-release') ? 1 : 0;

if ($Config{'version'} lt '5.8.0')
{
  print "As of version 2.0, collectl requires perl version 5.8 or greater.\n";
  print "See /opt/hp/collectl/docs/FAQ-collectl.html for details.\n";
#  exit;
}

$Version=  '2.4.2';
$Copyright='Copyright 2003-2008 Hewlett-Packard Development Company, L.P.';
$License=  "collectl may be copied only under the terms of either the Artistic License\n";
$License.= "or the GNU General Public License, which may be found in the source kit";

# get the path to the exe from the program location, noting different handling
# of path resolution for XC and non-XC, noting if a link and not XC, we
# need to follow it, possibly multiple times!  Furthermore, if the link is
# a relative one, we need to prepend with the original program location or
# $BinDir will be wrong.
if (!$XCFlag)
{
  $link=$0;
  $ExeName='';
  until($link eq $ExeName)
  {
    $ExeName=$link;    # possible exename
    $link=(!defined(readlink($link))) ? $link : readlink($link);
  }
}
else
{
  $ExeName=(!defined(readlink($0))) ? $0 : readlink($0);
  $ExeName=dirname($0).'/'.$ExeName    if $ExeName=~/^\.\.\//;
}

$BinDir=dirname($ExeName);
$Program=basename($ExeName);
$Program=~s/\.pl$//;    # remove extension for production
$MyDir= ($PcFlag) ?   `cd` : `pwd`;
$Cat=   ($PcFlag) ? 'type' : 'cat';
$Sep=   ($PcFlag) ?   '\\' : '/';
chomp $MyDir;

# This is a little messy.  In playback mode of process data, we want to use
# usernames instead of UIDs, so we need to know if we need to know if it's
# the same node and hence we need our name.  This could be different than $Host
# which was recorded with the data file and WILL override in playback mode. 
# We also need our host name before calling initRecord() so we can log it at 
# startup as well as for naming the logfile.
$myHost=($PcFlag) ? `hostname` : `/bin/hostname`;
$myHost=(split(/\./, $myHost))[0];
chomp $myHost;
$Host=$myHost;

# If we ever want to write something to /var/log/messages, we need this which
# we obviously can't include on a pc.
require "Sys/Syslog.pm"    if !$PcFlag;

# Load include files and optional PMs if there
require "$BinDir/formatit.ph";
$zlibFlag= (eval {require "Compress/Zlib.pm" or die}) ? 1 : 0;
$hiResFlag=(eval {require "Time/HiRes.pm" or die}) ? 1 : 0;

# may be overkill, but we want to throttle max errors/day to prevent runaway.
$zlibErrors=0;

# These variables only used once in this module and hence generate warnings
undef @lustreCltDirs;
undef @lustreCltOstDirs;
undef @lustreOstSubdirs;
undef %playbackSettings;
$recHdr1=$miniDateTime=$miniFiller=$DaemonOptions='';
$OstNames=$MdsNames=$LusDiskNames=$LusDiskDir='';
$NumLustreCltOsts=$NumLusDisks=$MdsFlag=0;
$NumSlabs=$SlabGetProc=$SlabSkipHeader=$newSlabFlag=0;
$wideFlag=$coreFlag=$newRawFlag=0;
$totalCounter=0;
$NumCpus=$NumDisks=$NumNets=$DiskNames=$NetNames=$HZ='';
$NumOst=$NumFans=$NumPwrs=$NumTemps=0;
$OFMax=$SBMax=$DQMax=$FS=$ScsiInfo=$cls=$HCAPortStates='';
$SlabVersion=$XType=$XVersion='';
$dentryFlag=$inodeFlag=$filenrFlag=$supernrFlag=$dquotnrFlag=0;

# Check the switches to make sure none requiring -- were specified with -
# since getopts doesn't!  Also save the list of switches we were called with.
$cmdSwitches=preprocSwitches();

# These are the defaults for interactive and daemon subsystems
$SubsysDefInt='cdn';
$SubsysDefDaemon='cdlmnstx';

# We want to load any default settings so that user can selectively 
# override them.  We're giving these starting values in case not
# enabled in .conf file.  We later override subsys if interactive
$SubsysDef=$SubsysCore=$SubsysDefDaemon;
$Interval=     10;
$Interval2=    60;
$Interval3=   300;
$LimSVC=       30;
$LimIOS=       10;
$LimLusKBS=   100;
$LimLusReints=1000;
$LimBool=       0;
$Port=       1234;
$Timeout=      10;
$MaxZlibErrors=20;
$LustreSvcLunMax=10;
$LustreMaxBlkSize=512;
$LustreConfigInt=1;
$InterConnectInt=900;
$HeaderRepeat=20;
$DefNetSpeed=10000;

$Passwd=       '/etc/passwd';
$Grep=         '/bin/grep';
$Egrep=        '/bin/egrep';
$Ps=           '/bin/ps';
$Rpm=          '/bin/rpm';
$Ethtool=      '/sbin/ethtool';
$Lspci=        '/sbin/lspci';
$Lctl=         '/usr/sbin/lctl';

# Standard locations
$SysIB='/sys/class/infiniband';

# These aren't user settable but are needed to build the list of ALL valid
# subsystems
$SubsysDet=   "CDEFLNTXYZ";
$SubsysExcore="fiy";

# These are the subsystems allowed in brief mode
$BriefSubsys="cdfFlmnstxy";    # note - use of y requires SAME intervals!

$configFile='';
$ConfigFile='collectl.conf';
$daemonFlag=$debug=0;
GetOptions('C=s'      => \$configFile,
           'D!'       => \$daemonFlag,
           'd=i'      => \$debug,
           'config=s' => \$configFile,
           'daemon!'  => \$daemonFlag,
           'debug=i'  => \$debug
           ) or error("type -h for help");

# if config file specified and a directory, prepend to default name otherwise
# use the whole thing as the name.
$configFile.="/$ConfigFile"    if $configFile ne '' && -d $configFile;;
loadConfig();

# These can get overridden after loadConfig(). Others can as well but this is 
# a good place to reset those that don't need any further manipulation
$limSVC=$LimSVC;
$limIOS=$LimIOS;
$limBool=$LimBool;
$limLusKBS=$LimLusKBS;
$limLusReints=$LimLusReints;
$headerRepeat=$HeaderRepeat;

# let's also see if there is a terminal attached.  this is currently only 
# an issue for -M1, but we may need to know some day for other reasons too.
# but PCs can only run on a terminal...
$termFlag=(open TMP, "</dev/tty") ? 1 : 0;
$termFlag=0    if $daemonFlag;
$termFlag=1    if $PcFlag;
close TMP;

$count=-1;
$numTop=0;
$showPHeaderFlag=$showMergedFlag=$showHeaderFlag=$showSlabAliasesFlag=$showRootSlabsFlag=0;
$verboseFlag=$procmemFlag=$vmstatFlag=$alignFlag=0;
$quietFlag=$utcFlag=$procioFlag=0;
$address=$beginTime=$endTime=$filename=$flush='';
$limits=$lustreSvcs=$procopts=$runTime=$subOpts=$playback=$playbackFile=$rollLog='';
$groupFlag=$msgFlag=$niceFlag=$plotFlag=$sshFlag=$wideFlag=$rawFlag=$sexprFlag=0;
$userOptions=$userInterval=$userSubsys=$slabopts=$custom=$sexprType=$sexprDir='';
$rawtooFlag=$autoFlush=0;

# Since --top has an optional argument, we need to see if it was specified without
# one and stick in the default
for (my $i=0; $i<scalar(@ARGV); $i++)
{
  if ($ARGV[$i]=~/--to/)
  {
    splice(@ARGV, $i+1, 0, 10)    if $i==(scalar(@ARGV)-1) || $ARGV[$i+1]=~/^-/;
    last;
  }
}

# now that we've made it through first call fo Getopt, disable pass_through so
# we can catch any errors in parameter names.
Getopt::Long::Configure('no_pass_through');
GetOptions('align!'     => \$alignFlag,
           'A=s'        => \$address,
           'address=s'  => \$address,
           'b=s'        => \$beginTime,
           'begin=s'    => \$beginTime,
	   'c=i'        => \$count,
           'count=i'    => \$count,
           'e=s'        => \$endTime,
           'end=s'      => \$endTime,
	   'f=s'        => \$filename,
   	   'filename=s' => \$filename,
           'F=i'        => \$flush,
           'flush=i'    => \$flush,
           'G!'         => \$groupFlag,
           'group!'     => \$groupFlag,
           'i=s'        => \$userInterval,
           'interval=s' => \$userInterval,
	   'h!'         => \$hSwitch,
           'help!'      => \$hSwitch,
           'l=s'        => \$limits,
           'limits=s'   => \$limits,
	   'L=s'        => \$lustreSvcs,
	   'lustresvc=s'=> \$lustreSvcs,
	   'm!'         => \$msgFlag,
           'messages!'  => \$msgFlag,
           'o=s'        => \$userOptions,
           'options=s'  => \$userOptions,
	   'O=s'        => \$subOpts,
           'subopts=s'  => \$subOpts,
	   'N!'         => \$niceFlag,
           'nice!'      => \$niceFlag,
	   'p=s'        => \$playback,
           'playback=s' => \$playback,
	   'P!'         => \$plotFlag,
           'quiet!'     => \$quietFlag,
           'plot!'      => \$plotFlag,
	   'r=s'        => \$rollLog,
           'rolllogs=s' => \$rollLog,
	   'R=s'        => \$runTime,
           'runtime=s'  => \$runTime,
           's=s'        => \$userSubsys,
           'sep=s'      => \$SEP,
           'subsys=s'   => \$userSubsys,
	   'S!'         => \$sshFlag,
           'ssh!'       => \$sshFlag,
	   'top=i'      => \$numTop,
           'T=s'        => \$timeOffset,
           'timezone=s' => \$timeOffset,
           'utc!'       => \$utcFlag,
	   'v!'         => \$vSwitch,
           'version!'   => \$vSwitch,
	   'V!'         => \$VSwitch,
           'showdefs!'  => \$VSwitch,
	   'w!'         => \$wideFlag,
           'x!'         => \$xSwitch,
           'helpextend!'=> \$xSwitch,
	   'Y=s'        => \$slabopts,
           'slabopts=s' => \$slabopts,
	   'Z=s'        => \$procopts,
	   'procopts=s' => \$procopts,

           # New since V2.0.0
           'custom=s'      => \$custom,
	   'headerrepeat=i'=> \$headerRepeat,
           'procmem!'      => \$procmemFlag,
           'verbose!'      => \$verboseFlag,
           'vmstat!'       => \$vmstatFlag,
           'showsubsys!'   => \$showSubsysFlag,
           'showoptions!'  => \$showOptionsFlag,
           'showsubopts!'  => \$showSuboptsFlag,
	   'showheader!'   => \$showHeaderFlag,
           'showplotheader!'  =>\$showPHeaderFlag,
	   'showslabaliases!' =>\$showSlabAliasesFlag,
	   'showrootslabs!'   =>\$showRootSlabsFlag,
           'rawtoo!'       => \$rawtooFlag,
           'sexpr=s'       => \$sexprType,
           'procio!'       => \$procioFlag,
           ) or error("type -h for help");

#    O p e n    A    S o c k e t  ?

# It's real important we do this as soon as possible because if someone runs
# us in this mode, like 'colmux', and an error occurs the caller would still
# be hanging around waiting for someone to connect to that socket!  This way
# we connect, report the error and exit and the caller is able to detect it.

$addrFlag=0;
if ($address ne '')
{
  ($address,$port)=split(/:/, $address);
  $port=$Port    if !defined($port);

  $socket=new IO::Socket::INET(
      PeerAddr => $address, 
      PeerPort => $port, 
      Proto    => 'tcp', 
      Timeout  => $Timeout);
  error("Could not create socket to $address:$port")
      if !defined($socket);
  print "Socket opened on $address:$port\n"    if $debug & 1;
  $addrFlag=1;
}

# We used to trap these before we opened the socket, but then we couldn't
# send the message back to the called cleanly!
if ($addrFlag)
{
  error("-p not allowed with -A")       if $playback ne '';
  error("-D not allowed with -A")       if $daemonFlag;
}

# Since the output could be intended for a socket (called from colgui/colmux),
# we need to do after we open the socket.
error()            if $hSwitch;
showVersion()      if $vSwitch;
showDefaults()     if $VSwitch;
extendHelp()       if $xSwitch;
showSubsys()       if $showSubsysFlag;
showOptions()      if $showOptionsFlag;
showSubopts()      if $showSuboptsFlag;
showSlabAliases($slabopts)  if $showSlabAliasesFlag || $showRootSlabsFlag;

#    H a n d l e    V 2 . 0    R e m a p p i n g s    F i r s t

if ($verboseFlag+$vmstatFlag+$procmemFlag+$procioFlag || $custom ne '')
{
  $temp="--verbose, --vmstat, --procmem, --procio or --custom";
  error("can't use -P with $temp")    if $plotFlag;
  error("can't use -f with $temp")    if $filename ne '';
  error("can't mix --custom with any of --verbose, --vmstat, --procmem or procio")
      if $custom ne '' && ($verboseFlag+$vmstatFlag+$procmemFlag+$procioFlag);

  # either custom or standard.  need to set verbose flag so we skip brief processing
  # in printTerm()
  $verboseFlag=1;
  if ($custom ne '')
  {
    # note - if subsys invalid, it will get caught later
    ($miniName, $temp)=split(/:/, $custom);
    $miniName.=".ph"    if $miniName!~/\./;

    # this is getting very elaborate but I hate misleading error messages
    $tempName=$miniName;
    $miniName="$BinDir\$miniName"    if !-e $miniName;
    if (!-e "$miniName")
    {
      $temp="can't find custom file '$tempName' in ./";
      $temp.=" OR $BinDir/"    if $BinDir ne '.';
      error($temp)             if !-e "$miniName";
    }
    require $miniName;

    # the basename is the name of the function and also remove extension.
    $miniName=basename($miniName);
    $miniName=(split(/\./, $miniName))[0];
  }
  elsif ($vmstatFlag)
  {
    # When forcing a value for $subsys we also need to make it look like
    # that's what the user specified.
    error("no subsystems can be specified for -M2")    if $userSubsys ne '';
    $subsys=$userSubsys="cm";
  }
  elsif ($procmemFlag || $procioFlag)
  {
    # Force -s to be Z
    error("-s not allowed with --procmem or --procio")      if $userSubsys ne '';
    $subsys=$userSubsys="Z";
  }
}

# As part of the conversion to getopt::long, we need to know the actual switch
# values as entered by the user.  Those are stored in '$userXXX' and then that
# is treated as one used to handle opt_XXX.
$options= $userOptions;
$interval=($userInterval ne '') ? $userInterval : $Interval;
$subsys=  ($userSubsys ne '')   ? $userSubsys   : $SubsysCore;

# Other mappings
$showHeaderFlag=1    if $debug & 4096;
error("--showheader in collection mode only supported on linux")
    if $PcFlag && $playback eq '';

#    S i m p l e    S w i t c h    C h e c k s

$utcFlag=1    if $options=~/U/;

# should I migrate a lot of other simple tests here?
error("you can only specify -s with --top with -p")        if $numTop ne 0 && $userSubsys ne '' && $playback eq '';
error("you cannot specify -f with --top")                  if $numTop ne 0 && $filename ne '';

error("--sexpr does not work in playback mode")            if $sexprType ne '' && $playback ne '';
error("--sexpr types are 'raw' and 'rate'")                if $sexprType ne '' && $sexprType!~/raw|rate/;
error("--rawtoo does not work in playback mode")           if $rawtooFlag && $playback ne '';
error("--rawtoo requires -f")                              if $rawtooFlag && $filename eq '';
error("--rawtoo requires -P or --sexpr")                   if $rawtooFlag && !$plotFlag && $sexprType eq '';
error("--rawtoo and -P requires -f")                       if $rawtooFlag && $plotFlag && $filename eq '';
error("--rawtoo cannot be used with -p")                   if $rawtooFlag && $playback ne '';
error("-ou/--utc only apply to -P format")                 if $utcFlag && !$plotFlag;
error("can't mix -ou with other formats")                  if $utcFlag && $options=~/[dDt]/;
error("-oz only applies to -P files")                      if $options=~/z/ && !$plotFlag;
error("--sep cannot be a '%'")                             if defined($SEP) && $SEP eq '%';
error("--sep only applied to plot format")                 if defined($SEP) && !$plotFlag;
error("--sep much be 1 character or a number")             if defined($SEP) && length($SEP)>1 && $SEP!~/^\d+$/;

error('--showheader not allowed with -f')                  if $filename ne '' && $showHeaderFlag;
error('--showmergedheader not allowed with -f')            if $filename ne '' && $showMergedFlag;
error('--showplotheader not allowed with -f')              if $filename ne '' && $showPHeaderFlag;

error("--align require HiRes time module")                 if $alignFlag && !$hiResFlag;

#    H a n d l e    D e f a u l t s

# The separator is either a space if not defined or the character supplied if non-numeric.  If it
# is numeric assume decimal and convert to the associated char code (eg 9=tab).
$SEP=' '                    if !defined($SEP);
$SEP=sprintf("%c", $SEP)    if $SEP=~/\d+/;

# Set default interval and subsystems for interactive mode unless already
# set, noting the default values above are for daemon mode.  To be consistent,
# we also need to reset $Interval and $SubsysDef noting if one sets a
# secondary interval but not the primary, we need to prepend it with 1 and
# keep the secondary
if (!$daemonFlag)
{
  $interval=$Interval=1    if $userInterval eq '';
  if ($userInterval ne '' && $userInterval=~/^(:.*)/)
  {
    $interval="1$userInterval";
    $Interval=1;
  }

  $SubsysDef=$SubsysDefInt;
  $subsys=$SubsysDef       if $userSubsys eq '';

  # If only doings slabs/processes, set the primary interval to be the
  # same as the secondary one (if specified) or else we'll see interval
  # headers for all the primaries
  $interval=$Interval="$1:$1"    if $subsys=~/^[yz]$/gi && $interval=~/:(\d+)/;
}

# --top forces -ot if not in playback mode.  if no process interval
# specified set it to the monitoring on
if ($numTop)
{
  if ($playback eq '')
  {
    $options.='t';
    $subsys='Z';
    $interval.=":$interval"    if $interval!~/:/;
  }
}

# subsystems  - must preceed +
error("+/- must start -s arguments if used")
                    if $subsys=~/[+-]/ && $subsys!~/^[+-]/;
error("invalid subsystem '$subsys'")
                    if $subsys!~/^[-+$SubsysCore$SubsysExcore$SubsysDet]+$/;

if ($subsys=~/[+-]/)
{
  $temp=$SubsysDef;
  if ($subsys=~/-(.*)/)
  {
    $pat=$1;
    $pat=~s/\+.*//;    # if followed by '+' string
    error("invalid subsystem follows '-'.  must be one or more of $SubsysCore")
	if $pat!~/^[$SubsysCore]+$/;
    $temp=~s/[$pat]//g;
  }

  # we've already validated subsystems below and so if someone adds a core
  # subsystem no harm is done.
  if ($subsys=~/\+(.*)/)
  {
    $pat=$1; 
    $pat=~s/-.*//;    # if followed by '-' string
    $temp="$temp$pat";
  }
  $subsys=$temp;
}

# under some circumstances we need to set verbose mode, which may have
# been cleared by setOutputFormat() as noted below, noting we end up calling
# setOutputFormat() twice since some local switches come from command line
# switches but in playback mode others come from file header.
setOutputFormat();
$verboseFlag=1    if $filename ne '' || $daemonFlag;
$briefFlag=$verboseFlag ? 0 : 1;
if ($briefFlag)
{
  # This is tricky as the main logic for checking intervals lives further
  # down the code and says it needs to be there!  So, let's do a very 
  # minimal/temporary thing here, noting '$interval' is always defined but
  # not yet validated so it can still contain a ':'.  '$interval2' not
  # yet defined so we either use default or what's in '$interval'.
  $temp1=$interval;
  $temp2=$Interval2;    # default
  if ($interval=~/:/)
  {
    @temp=split(/:/, $interval);
    $temp1=($temp[0] eq '') ? $Interval : $temp[0];
    $temp2=$temp[1]    if $temp[1] ne '';
  }

  # if more than one subsys and one of them is 'y', they MUST have same
  # interval.
  error("main and secondary intervals must match when -sy included OR use --verbose")
      if length($subsys)>1 && $subsys=~/y/ && $temp1!=$temp2;
}

#    L i n u x    S p e c i f i c

if (!$PcFlag)
{
  # This matches THIS host, but in playback mode will be reset to the target
  $Kernel=`uname -r`;
  chomp $Kernel;
  setKernelFlags($Kernel);

  $LocalTimeZone=`date +%z`;
  chomp $LocalTimeZone;

  # Some distros put lspci in /usr/sbin, so take one last look there before
  # complaining, but only if in record mode AND if looking at interconnects
  if (!-e $Lspci && $playback eq '' && $subsys=~/x/)
  {
    error("can't find '$Lspci' or '/usr/sbin/lspci' which is require for -sx\n".
	"If somewhere else, move it or define in collectl.conf")
            if (!-e "/usr/sbin/lspci");
    $Lspci='/usr/sbin/lspci';    # Looks like it's here
  }

  # Do something similar with 'ethtool' or but if not there disable it!
  if (!-e $Ethtool && $playback eq '')
  {
    $Ethtool='/usr/sbin/ethtool';
    if (!-e $Ethtool)
    {
      logmsg("W", "Can't find '$Ethtool' or '/usr/sbin/lspci'\n".
	   "Interface speeds in header will be disabled");
      $Ethtool='';
    }
  }
}

#    C o m m o n    I n i t i a l i z a t i o n

# We always want to flush terminal buffer in case we're using pipes.
$|=1;

# Save architecture name as well as perl version.
$SrcArch= $Config{"archname"};
$PerlVers=$Config{"version"};

# If the user explicitly uses --rawtoo, we write to the raw file.
# If the user specified -f but not in plot or sexpr format, we also write to raw
# Finally, set a flag to indicate we're writing to rolling logs (unless just --sexpr)
$rawFlag=$rawtooFlag;
$rawFlag=1    if $filename ne '' && !$plotFlag && $sexprType eq '';
$logToFileFlag=($filename ne '') ? 1 : 0;
print "RawFlag: $rawFlag PlotFlag: $plotFlag  SexprType: $sexprType\n"    if $debug & 1;

error("-G requires data collection to a file") 
    if $groupFlag && ($playback ne '' || $filename eq '');

($lustreSvcs, $lustreConfigInt)=split(/:/, $lustreSvcs);
$lustreSvcs=""                      if !defined($lustreSvcs);
$lustreConfigInt=$LustreConfigInt   if !defined($lustreConfigInt);
error("Valid values for -L are c, m and o")    
    if $lustreSvcs!~/^[cmo]*$/;
error("lustre config check interval must be numeric")
    if $lustreConfigInt!~/^\d+$/;

# NOTE - technically we could allow fractional polling intervals without
# HiRes, but then we couldn't properly report the times.
error("-i not allowed with -p")    if $userInterval ne '' && $playback ne '';
if ($interval=~/\./ && !$hiResFlag)
{
  $interval=int($interval+.5);
  $interval=1    if $interval==0;
  print "need to install HiRes to use fractional intervals, so rounding to $interval\n";
}

# some restrictions of plot format -- can't send to terminal for slabs or
# processes unless only 1 subsystem selected.  quite frankly I see no reason
# to ever do it but there are so damn many other odd switch combos we might
# as well catch these too.
error("to display on terminal using -sY with -P requires only -sY")
    if $plotFlag && $filename eq '' && $subsys=~/Y/ && length($subsys)>1;
error("to display on terminal using -sZ with -P requires only -sZ")
    if $plotFlag && $filename eq '' && $subsys=~/Z/ && length($subsys)>1;

# No great place to put this, but at least here it's in you face!  There are times 
# when someone may want to automate the running of collectl to playback/convert 
# logs from crontab for the day before and this is the easiest way to do that.
# While we're at it, there may be some other 'early' checks that need to be make
# in playback mode.
if ($playback ne "")
{
  ($day, $mon, $year)=(localtime(time))[3..5];
  $today=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
  $playback=~s/TODAY/$today/;

  ($day, $mon, $year)=(localtime(time-86400))[3..5];
  $yesterday=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
  $playback=~s/YESTERDAY/$yesterday/;

  error("sorry, but -Z not allowed in -p mode.  consider grep")
      if $procopts ne '';
}

# linux box?
if ($SrcArch!~/linux/)
{
  error("record mode only runs on linux")    if $playback eq "";
  error("-N only works on linux")            if $niceFlag;
}

# flush
if ($flush ne '')
{
  error("-F must be numeric")             if $flush!~/^\d+$/;
  error("-p not allowed with -F")         if $playback ne '';
}

# daemon node
if ($daemonFlag)
{
  error("no debugging allowed with -D")      if $debug;
  error("-D can only be used by root")       if `whoami`!~/root/i;
  error("-D requires -f")                    if $filename eq "";
  error("-p not allowed with -D")            if $playback ne "";

  if (-e $PidFile)
  {
    # see if this pid matches a version of collectl.  If not, we'll overwrite
    # it further on so not to worry, but at least record a warning.
    $pid=`$Cat $PidFile`;
    $command="ps -eo pid,command | $Grep -v grep | $Grep collectl | $Grep $pid";
    $ps=`$command`;
    error("a daemonized collectl already running")    if $ps!~/^\s*$/;
  }
}

# count
if ($count!=-1)
{
  error("-c must be numeric")       if $count!~/^\d+$/;
  error("-c conflicts with -r and -R")
              if $endTime ne "" || $rollLog ne "" || $runTime ne "";
  $count++    # since we actually need 1 extra interval
}

if ($limits ne '')
{
  error("-l only makes sense for -s D/L/l")    if $subsys!~/[DLl]/;
  @limits=split(/-/, $limits);
  foreach $limit (@limits)
  {
    error("invalid value for -l: $limit")    
	if $limit!~/^SVC:|^IOS:|^LusKBS:|^LusReints:|^OR|^AND/;
    ($name,$value)=split(/:/, $limit);
    $limBool=0    if $name=~/OR/;
    $limBool=1    if $name=~/AND/;
    next          if $name=~/AND|OR/;
    
    error("-l SVC and IOS only apply to -sD")            if $name!~/^Lus/ && $subsys=~/L/;
    error("-l LusKBS and LusReint only apply to -sL")    if $name=~/^Lus/ && $subsys=~/D/;
    error("limit for $limit not numeric")    if $value!~/^\d+$/;
    $limSVC=$value          if $name=~/SVC/;
    $limIOS=$value          if $name=~/IOS/;
    $limLusKBS=$value       if $name=~/LusKBS/;
    $limLusReints=$value    if $name=~/LusReints/;
  }
}

# options
error("invalid option")    if $options ne "" && $options!~/^[\^12aAcdDFGghHimnpPsStTuxXz]+$/g;
error("-oi only supported interactively with -P to terminal")    
    if $options=~/i/ && ($playback ne '' || !$plotFlag || $filename ne '');
$miniDateFlag=($options=~/d/i) ? 1 : 0;
$miniTimeFlag=($options=~/T/)  ? 1 : 0;
error("use only 1 of -o dDt") 
    if ($miniDateFlag && $miniTimeFlag) || ($options=~/d/ && $options=~/D/);
error("-ot only applies to terminal output")
                             if $options=~/t/ && $filename ne "";
error("-ot cannot be used with -A")
                             if $options=~/t/ && $addrFlag;
error("-o h/H conflicts with -f")
                             if $options=~/h/i && $filename ne "";
error("option $1 only apply to -P")
                             if !$plotFlag && $options=~/([12ac])/;
error("-oa conflicts with -oc") 
                             if $options=~/a/ && $options=~/c/;
error("-oa conflicts with -ou") 
                             if $options=~/a/ && $options=~/u/;

# Some -oh specifics
if (!$hiResFlag && $options=~/m/)
{
  print "need to install HiRes to report fractional time with -om, so ignoring\n";
  $options=~s/m//;
}

$pidOnlyFlag=($subOpts=~/P/) ? 1 : 0;

# We always compress files unless zlib not there or explicity turned off
$zFlag=($options=~/z/ || $filename eq "") ? 0 : 1;
if (!$zlibFlag && $zFlag)
{
  $options.="z";
  $zFlag=0;
  logmsg("W", "Zlib not installed so not compressing file(s).  Use -oz to get rid of this warning.");
}

$precision=($options=~/(\d+)/) ? $1 : 0;
$FS=".${precision}f";

# where to look for nfs client/server data
$procNfs="/proc/net/rpc/nfs";
$procNfs.="d"    if $subOpts!~/C/;

# playback mode specific
error('--showmerged only applied to playback mode')    if $playback eq '' && $showMergedFlag;
if ($playback ne "")
{
  error("-T must be in hours with optional leading '-'")
      if defined($timeOffset) && $timeOffset!~/^-?\d+/;

  $playback=~s/['"]//g;    # in case quotes passed through from script
  error("--align only applies to record mode")    if $alignFlag;
  error("-p filename must end in '*', 'raw' or 'gz'") 
      if $playback!~/\*$|raw$|gz$/;
  error("MUST specify -P if -p and -f")      if $filename ne "" and !$plotFlag;

  foreach $file (glob($playback))
  {
    # won't happen if file string had wildcards because then glob would
    # only find read files.
    error("can't find '$file'")              if !-e $file;

    # this is a great place to print headers since we're already looping through glob
    if ($showHeaderFlag)
    {
      next    if $file!~/raw/;

      # remember, this has to work on a pc as well, so can't use linux commands
      print "$file\n";
      my $return;
      $return=open TMP, "<$file"                              if $file!~/gz$/;
      $return=($ZTMP=Compress::Zlib::gzopen($file, 'rb'))     if $file=~/gz$/;
      logmsg("F", "Couldn't open '$file' for reading")  if !defined($return) || $return<1;

      while (1)
      {
	$line=<TMP>                 if $file!~/gz$/;
	$ZTMP->gzreadline($line)    if $file=~/gz$/;
	last    if $line!~/^#/;
	print $line;
      }
      print "\n";
      close TMP           if $file!~/gz$/;
      $ZTMP->gzclose()    if $file=~/gz$/;
    }
  }
  exit    if $showHeaderFlag;
}

# end time
$purgeDays=0;

# if specified make sure valid
error("-b and -e only apply to -p")
    if $playback eq "" && ($beginTime ne "" || $endTime ne "");
checkTime("-b", $beginTime)    if $beginTime ne "";
checkTime("-e", $endTime)      if $endTime ne "";
 
$endSecs=0;
if ($runTime ne "")
{
  error("pick either -r or -R")   if $rollLog ne "";
  error("invalid -R format")      if $runTime!~/^(\d+)[wdhms]{1}$/;
  $endSecs=$1;
  $endSecs*=60        if $runTime=~/m/;
  $endSecs*=3600      if $runTime=~/h/;
  $endSecs*=86400     if $runTime=~/d/;
  $endSecs*=604800    if $runTime=~/w/;
  $endSecs+=time;
}

# log file rollover
my $rollSecs=0;
my $expectedHour;
if ($rollLog ne '')
{
  error("-r requires -f")                        if $filename eq "";
  ($rollTime,$purgeDays,$rollIncr)=split(/,/, $rollLog);
  $purgeDays=7       if !defined($purgeDays) || $purgeDays eq '';
  $rollIncr=60*24    if !defined($rollIncr)  || $rollIncr eq '';

  error("-r time must be in HH:MM format")       if $rollTime!~/^\d{2}:\d{2}$/;
  ($rollHour, $rollMin)=split(/:/, $rollTime);
  error("-r purge days must be an integer")      if $purgeDays!~/^\d+$/;
  error("-r increment must be an integer")       if $rollIncr!~/^\d+$/;
  error("-r time invalid")                       if $rollHour>23 || $rollMin>59;
  error("-r increment must be a factor of 24 hours")
      if int(1440/$rollIncr)*$rollIncr!=1440;
  error("if -r increment>1 hour, must be multiple of 1 hour")
      if $rollIncr>60 && int($rollIncr/60)*60!=$rollIncr;
  error("roll time must be specified in 1st interval")
      if ($rollHour*60+$rollMin)>$rollIncr;

  # Getting the time to the next interval can be tricky because we have to
  # worry about daylight savings time.  This IS further complicated by
  # having to deal with intervals.  The safest thing to do is using brute-force.
  # I also have to write the following down because I know I'll forget it and
  # think it's a bug!  Assume you're going to roll every two hours (or more) and it's
  # midnite of the day to move clocks forward (probably never going happen but...).
  # 2 hours from midnight is 3AM! so we subtract an hour and now since we're before the
  # time change we create a logfile with a time of 1AM.  BUT the next log gets created
  # at AM and everyone is happy!

  # We start at the first interval of the day and then step forward until we 
  # pass our current time.  Then we see if DST is involved and then we're done!
  # Note however, if the interval is an hour or less, DST takes care of itself!
  # Step 1 - Get current date/time
  my ($sec, $min, $hour, $day, $mon, $year)=localtime(time);
  my $timeNow=sprintf "%d%02d%02d %02d:%02d:%02d", 
                       $year+1900, $mon+1, $day, $hour, $min, $sec;
  $rollToday=timelocal(0, $rollMin, $rollHour, $day, $mon, $year);

  # Step 2 - step through each increment (note in most cases there is only 1!)
  #          looking for each one > now
  my ($timeToRoll, $lastHour);
  $expectedHour=$rollHour;
  foreach ($rollSecs=$rollToday;; $rollSecs+=$rollIncr*60)
  {
    # Get the corresponding time and if not the first one see if the
    # time was changed
    my ($sec, $min, $hour, $day, $mon, $year)=localtime($rollSecs);
    $timeToRoll=sprintf "%d%02d%02d %02d:%02d:%02d", $year+1900, $mon+1, $day, $hour, $min, $sec;
    #print "CurTime: $timeToRoll  CurHour: $hour  ExpectedHour: $expectedHour\n";

    if ($rollIncr>60)
    {
      # Tricky...  We can have expected hour differ from the current one by
      # exactly 1 hour when we hit a DST time change.  However, while a 
      # simple subtraction will yield +/- 1, the one special case is when 
      # we're rolling logs at 00:00 and get an hour of 23, which generates a
      # diff of -23 when we really want +1.
      my $diff=($expectedHour-$hour);
      $specialFlag=($diff==-23) ? 1 : 0;
      $diff=1    if $specialFlag;
      $rollSecs+=$diff*3600;     # diff is USUALLY 0

      # When in this 'special' situation, '$timeToRoll' is pointing to the previous
      # day so we need to reset $timeToRoll, but only AFTER we updated rollSecs.
      if ($specialFlag)
      {
        ($sec, $min, $hour, $day, $mon, $year)=localtime($rollSecs);
        $timeToRoll=sprintf "%d%02d%02d %02d:%02d:%02d", $year+1900, $mon+1, $day, $hour, $min, $sec;
      }
      $expectedHour+=$rollIncr/60;
      $expectedHour%=24;
    }
    last    if $timeToRoll gt $timeNow;
    $lastHour=$hour;
  }
  ($sec, $min, $hour, $day, $mon, $year)=localtime($rollSecs);
  $rollFirst=sprintf "%d%02d%02d %02d:%02d:%02d", $year+1900, $mon+1, $day, $hour, $min, $sec;
  logmsg("I", "First log rollover will be: $rollFirst");
}

# for option 't' we do HOME ERASE, which only works on ascii terminals
$cls=sprintf("%c[H%c[J", 27, 27)   if $options=~/t/;

# if -N, set priority to 20
`renice 20 $$`    if $niceFlag;

# this sets all the xFlags as specified by -s.  At least one must be set to
# write to the 'tab' file.
setFlags($subsys);

# Couldn't find anywhere else to put this one...
error("-sT only works with -P for now (too much data)")
    if $TFlag && !$plotFlag;

if ($sshFlag)
{
  error("-S doesn't apply to daemon mode")      if $daemonFlag;
  error("-S doesn't apply to playback mode")    if $playback ne '';
  $stat=`cat /proc/$$/stat`;
  $myPpid=(split(/\s+/, $stat))[3];
}

###############################
#    P l a y b a c k    M o d e
###############################

if ($playback ne '')
{
  $numProcessed=0;
  $elapsedSecs=0;
  $preprocFlags=preprocessPlayback($playback);
  $lastPrefix=$prefixPrinted='';
  $saveSubOpts=$subOpts;    # in case specified
  while ($file=glob($playback))
  {
    # Unfortunately we need a more unique global name for the file we're doing
    $playbackFile=$file;

    # For now, we're going to skip files in error and process the rest.
    # Some day we may just want to exit on errors (or have another switch!)
    $ignoreFlag=0;
    foreach $key (keys %preprocErrors)
    {
      # some are file names and some just prefixes.
      if ($file=~/$key/)
      {
        ($type, $text)=split(/:/, $preprocErrors{$key}, 2);
	$modifier=($type eq 'E') ? 'due to error:' : 'because';
        logmsg($type, "*** Skipping '$file' $modifier $text ***");
	$ignoreFlag=1;
	next;
      }
    }
    next    if $ignoreFlag;

    print "\nPlaying back $file\n"    if $msgFlag || $debug & 1;
    $numProcessed++;
    $file=~/(.*-\d{8})-\d{6}\.raw[p]*/;
    $prefix=$1;
    if ($prefix ne $lastPrefix)
    {
      if ($msgFlag && defined($preprocMessages{$prefix}))
      {
        # Whatever the messages may be, we only want to display them once for
        # each set of files, that is files with the same prefix
        print "  >>> Forcing configuration change(s) for '$prefix-*'\n";
        for ($i=0; $i<$preprocMessages{$prefix}; $i++)
        {
          $key="$prefix|$i";
	  print "  >>> $preprocMessages{$key}\n"    if $file=~/$prefix/;
        }
      }

      # When we start a new prefix, that's the time to reset any variables that
      # span the set of common files.
      $lustreCltInfo='';
    }
    $lastPrefix=$prefix;

    # we need to initialize a bunch of stuff including these variables and the
    # starting time for the file as well as the corresponding UTC seconds.
    ($recVersion, $recDate, $recTime, $recSecs, $recTZ, $recInterval, $recSubsys)=initFormat($file);
    print "  ignoring redundant pre-collectl 1.3.0 -sd in favor of -sp in $file\n"    if $IgnoreDiskData;

    # Need to reset the globals for the intervals that gets recorded in the header.
    # Note the conditional on the assignments for i2 and i3.  This is because they SHOULD be
    # in the header as of V2.1.0 and I don't want to mask any problems if they're not.
    ($interval, $interval2, $interval3)=split(/:/, $recInterval);
    $interval2=$Interval2    if !defined($interval2) && $recVersion lt '2.1.0';
    $interval3=$Interval3    if !defined($interval2) && $recVersion lt '2.1.0';

    # At this point we've initialized all the variables that will get written to the common
    # header for one set of files for one day, so if the user had specified --showmerged, now
    # is the best/easiest time to do it.  We also need to set a flag so we only print the
    # header once for each set of merged files
    if ($showMergedFlag)
    {
      # I'm bummed I can't use '$lastPrefix', but we don't always execute the
      # outer loop and can't rest it in one place common to everyone...
      if ($prefix ne $prefixPrinted)
      {
        $commonHeader=buildCommonHeader(0);
        print $commonHeader;
      }
      $prefixPrinted=$prefix;
      next;
    }

    # generally, -O is ignored during playback other than to let us know the 
    # type of nfs data, but in the case of lustre, we actually use it to 
    # control potentially several ways the data can be displayed.  
    # therefore if specified by the user, override any of the lustre settings 
    # associated with the data.
    if ($saveSubOpts=~/[comBDMR]/)
    {
      $temp=$saveSubOpts;
      $temp=~s/[^comBDMR]//g;     # remove ALL but lustre switches from -O
      $subOpts=~s/[comBDMR]//g;   # now remove ALL lustre switches from -O
      $subOpts.=$temp;
    }

    # on the off chance that lustre data was collected with -O by not played
    # back, clear the lustre settings or else we're screw up the default
    # playback mode.
    $subOpts=~s/[BDMR]//g    if $subsys!~/l/i;

    # conversely, if data was collected using lustre -O options but lustre
    # wasn't active during the time this file was collected, the header will
    # indicate this log does NOT contain any lustre data but the -s will and 
    # so we need to turn off any -O lustre switches or else 'checkSubOpts()' 
    # will report a conflict.
    $subOpts=~s/B//g       if $subOpts=~/B/    && $CltFlag==0 && $OstFlag==0;
    $subOpts=~s/D//g       if $subOpts=~/D/    && $MdsFlag==0 && $OstFlag==0;
    $subOpts=~s/[MR]//g    if $subOpts=~/[MR]/ && $CltFlag==0;

    # Now we can check for valid/consistent sub-options
    checkSubOpts();          # Make sure valid
    setOutputFormat();       # use same values as for interactive mode

    # We need to set the 'coreFlag' based on whether or not any core 
    # subsystems in in playback file.
    $coreFlag=($recSubsys=~/[a-z]/) ? 1 : 0;

    # if a specific time offset wasn't selected, find difference between 
    # time collectl wrote out the log and the time of the first timestamp.
    if (!defined($timeOffset) && $recSecs ne '')
    {
      $year=substr($recDate, 0, 4);
      $mon= substr($recDate, 4, 2);
      $day= substr($recDate, 6, 2);
      $hour=substr($recTime, 0, 2);
      $min= substr($recTime, 2, 2);
      $sec= substr($recTime, 4, 2);
      $locSecs=timelocal($sec, $min, $hour, $day, $mon-1, $year-1900);
      $timeAdjust=$locSecs-$recSecs;
    }
    elsif (defined($timeOffset))
    {
      $timeAdjust=$timeOffset*3600;    # user override of default
    }
    else
    {
      $timeAdjust=0;   # logs generated with pre-V1.5.3 do anything without -T
    }
    printf "Adjust Time By: %d hours\n", $timeAdjust/3600   if $debug & 1;

    if ($subsys=~/D/ && $recSubsys=~/d/ && $recSubsys!~/c/)
    {
      print "file recorded with -sd and not -sc cannot be played back with -sD\n";
      next;
    }

    # Header already successfully read one, but what the heck...
    if (!defined($recVersion))
    {
      logmsg("E", "Couldn't read header for $file");
      next;
    }

    printf "Host: $Host  Version: %s  Date: %s  Time: %s  Interval: %s Subsys: $recSubsys\n",
              $recVersion, $recDate, $recTime, $recInterval
		  if $debug & 1;

    # Note - the prefix includes full path
    $zInFlag=($file=~/gz$/) ? 1 : 0;
    $file=~/(.*-\d{8})-\d{6}\.raw[p]*/;
    $prefix=$1;

    if ($prefix!~/$Host/)
    {
      print "ignoring $file whose header says recorded for $Host but whose name says otherwise!\n";
      next;
    }

    # we get a new output file (if writing to a file) for each prefix-date
    # combo, noting that $Host is a global pointing to the current host being
    # processed both in record as well as playback mode.  We also need to
    # track for terminal processing as well, so use a different flag for that
    $key="$prefix:$recDate";
    $newPrefixDate=(!defined($playback{$key})) ? 1 : 0;
    if ($newPrefixDate)
    {
      print "Prefix: $prefix  Host: $Host\n"    
	  if ($debug & 1) && !$logToFileFlag;
      $headersPrinted=$headersPrintedProc=$totalCounter=$prcFileCount=0;
      $newOutputFile=($filename ne '') ? 1 : 0;
      $playback{$key}=1;
    }
    $prcFileCount++    if $subsys=~/Z/;
    #print "NEW PREFIX: $newPrefixDate  NEW FILE: $newOutputFile\n";

    # set begin/end dates to that of collection file if none specified.  Note
    # that since the first interval is never reported, but rather used for base
    # point, we need to reduce begin time by 1 interval (if possible) so that 
    # the first interval reported matches the time we chose.
    $beginSecs=$endSecs=0;
    if ($beginTime ne "")
    {
      $temp=$recDate;
      $temp=~s/-.*//;    # get rid of time
      $beginTime="$temp-$beginTime"    if $beginTime!~/-/;
      $beginSecs=getSeconds($beginTime)-$interval;
    }
    if ($endTime ne "")
    {
      $temp=$recDate;
      $temp=~s/-.*//;    # get rid of time
      $endTime="$temp-$endTime"        if $endTime!~/-/;
      $endSecs=getSeconds($endTime);
    }

    if ($zInFlag)
    {
      $ZPLAY=Compress::Zlib::gzopen($file, "rb") or logmsg("F", "Couldn't open '$file'");
    }
    else
    {
      open PLAY, "<$file" or logmsg("F", "Couldn't open '$file'");
    }

    # only call this if generating plot data either in file or on terminal AND
    # only one time per output file
    if ($plotFlag && ($newOutputFile || $options=~/u/))
    {
      # Make sure that if the user specified -s, we override any setting in 
      # the file so appropriate logs get created.  It turns out if we're processing
      # both raw and rawp files, we only fall through here once and so need to know
      # we need to open ALL associated files which preproc() tells us via its flag.
      setFlags($subsys);
      $ZFlag=1    if $preprocFlags & 1;
 
      # If playback file has a prefix before its hostname things get more complicated
      # as we want to preserve that prefix and at the same time honor -f.
      $filespec=$filename;
      $filespec.=(-d $filespec) ? "$Sep$1" : "-$1"    if $prefix=~/(.+)-$Host/;

      # note we're only passing '$file' along in case we need diagnostics.
      $newfile=newLog($filespec, $recDate, $recTime, $recSecs, $recTZ, $file);
      if ($newfile ne '1')
      {
        # This is the most common failure mode since people rarely use -ou
        # and having 2 separate conditions gives us more flexibility in messages
        if ($options!~/u/)
        {
  	  print "  Plotfile '$newfile' already exists and will not be touched\n";
          print "  '-oc' to create a new one OR '-oa' to append to it\n";
        }
        else
	{
  	  print "  Plotfile '$newfile' exists and is newer than $file\n";
          print "  You must specify '-ocu' to force creation of a new one\n";
	}
        next;
      } 
      $newOutputFile=0;
    }

    # When playing back process data, if possible use /etc/passwd to translate
    # UIDs to username if the same host OR use the one specified in collectl.conf
    # if -OB.  Otherwise we just report the value.
    if ($ZFlag)
    {
      $passwdFile='';
      $passwdFile='/etc/passwd'    if $myHost eq $Host;
      $passwdFile=$Passwd          if $options=~/P/;
      loadUids($passwdFile)        if $passwdFile ne '';
    }

    # when processing data for a new prefix/date and printing on a terminal
    # we need to print totals from previous file(s) if there were any and 
    # reset total
    if ($filename eq '' && $newPrefixDate)
    {
      if ($options=~/A/ && $numProcessed>1)
      {
        printMini1Counters('A');
        printMini1Counters('T');
      }
      $elapsedSecs=0;
      resetMini1Counters();
    }

    # if a begin time, we start out in skip mode.
    # we need to init $newSeconds so debugging won't gen uninits on 1st pass
    $firstTime=1;
    $skip=($beginSecs) ? 1 : 0;

    undef($fileFrom);
    $fileThru=0;
    $newMarkerWritten=0;
    $lastSeconds=$newInterval=$newSeconds=0;
    $bytes=1;  # so no compression error on non-zipped files
    while (1)
    {
      # read a line from either zip file or plain ol' one and skip comments
      last    if ( $zInFlag && ($bytes=$ZPLAY->gzreadline($line))<1) ||
	         (!$zInFlag && !($line=<PLAY>)); 
      next    if $line=~/^#/;

      # Doncha love special cases?  Turns out when reading back process data
      # from a PRC file which was created from multiple logs, if a process from
      # one log comes up with the same pid as that of an earlier log, there's
      # no easy way to tell.  Now there is!
      writeInterFileMarker()
	  if $filename ne '' && $prcFileCount>1 && !$newMarkerWritten;
      $newMarkerWritten=1;
	  
      # if new interval, it really indicates the end of the last one but its
      # time is that of the new one so process last interval before saving.
      # if this isn't a valid interval marker the file somehow got corrupted
      # which was seen one time before flush error handling was put in.  Don't
      # if that was the problem or not so we'll keep this extra test.
      if ($line=~/^>>>/)
      {
        if ($line!~/^>>> (\d+\.\d+) <<</)
        {
 	  logmsg("E", "Corrupted file do to invalid time marker in '$file'\n".
  		      "Ignoring the rest of file.  Last valid marker: $newSeconds");
	  next;
        }

        $lastSeconds=$newSeconds;
        $newSeconds=$1+$timeAdjust;
        $newInterval=1;
  	$skip=0    if $beginSecs && $newSeconds>=$beginSecs;
        last       if $endSecs   && $newSeconds>$endSecs;

        # track thru times for each file to be used for totals/averages
        # in terminal mode
        $fileFrom=$newSeconds    if !$skip && !defined($fileFrom);
        $fileThru=$newSeconds;
        #printf "FROM: %s  THRU: %s\n", getTime($fileFrom), getTime($fileThru);
      }
      next    if $skip;

      # when new interval, since we don't have an end-of-interval marker,
      # print data for last one (except first time through)
      printf "PLAYBACK [%s]: $line", getTime($newSeconds)    if $debug & 64;
      intervalEnd($lastSeconds)    if  $newInterval && !$firstTime;

      # Skip redundant disk data in pre-1.3.0 raw file
      next    if $IgnoreDiskData && $line=~/^disk/;
      print $line    if $debug & 4;
      dataAnalyze($subsys, $line)  if !$newInterval;

      $newInterval=$firstTime=0;
    }
    if ($firstTime)
    {
      print "No records selected for playback!  Are -b/-e wrong?\n";
      next;
    }

    # normally samples will end on interval marker (even if last interval)
    intervalEnd($lastSeconds)    if $newInterval;

    $ZPLAY->gzclose()    if  $zInFlag;
    close PLAY           if !$zInFlag;

    # if we reported data from this file (we may have skipped it entirely if -b
    # used with mulitple files), calculate how many seconds reported on.
    if (!$skip)
    {
      # we always skip the beginning interval and if we terminated by hitting
      # our ending interval we need to add one back on because when we hit 
      # the end of the file without -e, the THRU date is pointing to the 
      # start of the next interval which has no data.
      $playbackSecs=$fileThru-$fileFrom-$interval;
      $playbackSecs+=$interval    if $endSecs && $newSeconds>$endSecs;
      $elapsedSecs+=$playbackSecs;
      #print "PLAYBACK SECS: $playbackSecs  PREFIX SECS: $elapsedSecs\n";
    }

    # for easier reading...
    print "\n"    if $debug & 1;

    # This should be pretty rare..
    logmsg("E", "Error reading '$file'\n")    if $bytes==-1;
  }

  # if printing to terminal, be sure to print averages & totals for last file
  # processed
  if ($options=~/A/ && $filename eq '')
  {
    printMini1Counters('A');
    printMini1Counters('T');
  }

  `stty echo`    if !$PcFlag && $termFlag;   # in -M1, we turned it off
  print "No files processed\n"    if !$numProcessed;
  exit;
}

###########################
#    R e c o r d    M o d e
###########################

# Would be nice someday to migrate all record-specific checks here
error("-T only applies to playback mode")    if defined($timeOffset);

# This is really a compound switch
if ($sexprType ne '')
{
  # If writing sexpr to a directory, we can override location.  If not writing
  # to a directory '$sexprDir' needs to be ''.
  ($sexprType, $sexprDir)=split(/,/, $sexprType);
  if ($filename eq '')
  {
    error("use of a directory with --sexpr requires -f")    if defined($sexprDir);
    $sexprDir='';
  }
  $sexprFlag=($sexprType eq 'raw') ? 1 : 2;

  # If user in fact specified -f, figure out where to write 'S' file
  if ($filename ne '')
  {
    $sexprDir=(-d $filename) ? $filename : dirname($filename)
      if !defined($sexprDir);
    error("the directory '$sexprDir' specified with --sexpr cannot be found")
      if !-d $sexprDir;
  }
}

# need to load even if interval is 0, but don't allow for -p mode
error("threads only currently supported in 2.6 kernels")
    if $procopts=~/\+/ && !$kernel2_6;
loadPids($procopts)     if $subsys=~/Z/;

# In case running on a cluster, record the name of the host we're running on.
# Track in collecl's log as well as syslog
$message="V$Version Beginning execution on $myHost...";
logmsg("I", $message);
logsys($message);

# initialize. noting if the user had only selected subsystems not supported
# on this platform, initRecord() will have deselected them!
initRecord();
error("no subsystems selected")    if $subsys eq '';
error("--procio features not enabled in this kernel")      if $procioFlag && !$processIOFlag;

if ($subsys=~/y/i && !$slabinfoFlag && !$slubinfoFlag)
{
  logmsg("W", "Slab monitoring disabled because neither /proc/slabinfo nor /sys/slab exists");
  $yFlag=$YFlag=0;
  $subsys=~s/y//ig;
}

# We can't do this until we know if the data structures exist.
loadSlabs($slabopts)    if $subsys=~/y/i;

# In case displaying output.  We also need the recorded version to match ours.
initFormat();
$recVersion=$Version;

# Since we have to check subOpts against data in recorded file, let's
# not do it twice, but we have to do it AFTER initFormat()
checkSubOpts();

# Last minute validation can only be done after initRecord() and I don't
# want to move it around (at least not now)
error("-sL only applies to MDS services when used with -OD")
    if $subsys=~/L/ && $NumMds && $subOpts!~/D/;
error("-OD only applies to SFS")
    if $subOpts=~/D/ && $sfsVersion eq '';

if ($options=~/x/i)
{
  error("exception reporting requires --verbose")
           if !$verboseFlag;
  error("exception reporting only applies to -sD and lustre OST details or MDS/Client summary")
           if ($subsys!~/[DLl]/ || ($subsys=~/L/ && $NumOst==0) || 
	      ($subsys=~/l/ && $NumMds+$CltFlag==0));
  error("exception reporting must be to a terminal OR a file in -P format")
           if ($filename ne "" && !$plotFlag) || ($filename eq "" &&  $plotFlag);
}

# demonize if necessary
if ($daemonFlag)
{
  # We need to make sure no terminal I/O
  open STDIN,  '/dev/null'     or logmsg("F", "Can't read /dev/null: $!");
  open STDOUT, '>/dev/null'  or logmsg("F", "Can't write to /dev/null: $!");
  open STDERR, '>/dev/null'  or logmsg("F", "Can't write to /dev/null: $!");

  # fork a child and exit parent, but make sure fork really works
  defined(my $pid=fork())     or logmsg("F", "Can't fork: $!");
  exit    if $pid;

  # Make REALLY sure we're disassociated
  setsid()                   or logmsg("F", "Couldn't setsid: $!");
  open STDIN,  '/dev/null'   or logmsg("F", "Can't read /dev/null: $!");
  open STDOUT, '>/dev/null'  or logmsg("F", "Can't write to /dev/null: $!");
  open STDERR, '>/dev/null'  or logmsg("F", "Can't write to /dev/null: $!");
  `echo $$ > $PidFile`;
}

######################################################
#
# ===>   WARNING: No Writing to STDOUT beyond   <=====
#                 since we're now daemonized!
#
######################################################

$SIG{"INT"}=\&sigInt;      # for ^C
$SIG{"TERM"}=\&sigTerm;    # default kill command
$SIG{"USR1"}=\&sigUsr1;    # for flushing gz I/O buffers
$SIG{"PIPE"}=\&sigPipe;    # socket comm errors

$flushTime=($flush ne '') ? time+$flush : 0;

# intervals...  note that if no main interval specified, we use
# interval2 (if defined OR if only doing slabs/procs) and if not 
# that, interval3. Also, if there is an interval3, interval3 IS defined, so we
# have to compare it to ''.  Also note that since newlog() can change subsys
# we need to wait until after we call it to do interval/limit validation.
$origInterval=$interval;
($interval, $interval2, $interval3)=split(/:/, $interval);
error("interval2 only applies to -s y,Y or Z")
    if defined($interval2) && $interval2 ne '' && $subsys!~/[yYZ]/;
error("interval3 only applies to -sE")     
    if defined($interval3)  && $subsys!~/E/;
$interval2=$Interval2   if !defined($interval2);
$interval3=$Interval3   if !defined($interval3);
$interval=$interval2    if $origInterval=~/^:/ || $subsys=~/^[yz]+$/i;
$interval=$interval3    if $origInterval=~/^::/;

if ($interval!=0)
{
  if ($subsys=~/[yYZ]/)
  {
    error("interval2 must be >= main interval")
	if $interval2<$interval;
    $limit2=$interval2/$interval;
    error("interval2 must be a multiple of main interval")
	if $limit2!=int($interval2/$interval);
  }
  if ($subsys=~/E/)
  {
    error("interval3 must be >= main interval")
	if $interval3<$interval;
    $limit3=$interval3/$interval;
    error("interval3 must be a multiple of main interval")
	if $limit3!=int($interval3/$interval);
  }
}
else
{
  # While we don't want any pauses, we also want to limit the number
  # of collections to the same number as would be taken during normal
  # activities.
  $interval2=$interval3=0;
  $limit2=6;
  $limit3=30;
  print "Lim2: $limit2  Lim3: $limit3\n"    if $debug & 1;
}

# Note that even if printing in plotting mode to terminal we STILL call newlog
# because that points the LOG, DSK, etc filehandles at STDOUT
# Also, note that in somecase we set non-compressed files to autoflush
$autoFlush=1    if $flush ne '' && $flush<=$interval && !$zFlag;
newLog($filename, "", "", "", "", "")    if ($filename ne '' || $plotFlag || $showPHeaderFlag);

# We want all final runtime parameters defined before doing this
if ($showHeaderFlag && $playback eq '')
{
  initRecord();
  my $temp=buildCommonHeader(0, undef);
  printText($temp);
  exit;
}

# Alas, we need a lot of stuff set up before this including the call to newLog()
if ($showPHeaderFlag)
{
  printHeaders();
  exit;
}

# If HiRes had been loaded and we're NOT doing 'time' tests, we want to 
# align each interval via sigalrm
if ($hiResFlag && $interval!=0)
{
  # Default for deamons is to always align to the primary interval
  $alignFlag=1    if $daemonFlag;

  # sampling is calculated as multiples of a base time and we set that
  # time such that our next sample will occur on the next whole second,
  # just to make integer sampling align on second boundaries
  $AlignInt=$interval;
  $BaseTime=(time-$AlignInt+1)*1000000;

  # For aligned time we want to align on either the primary interval OR if
  # we're monitoring for processes or slabs, on the secondary one.  To make
  # all sample times align no matter when they were started, we align based
  # on a time of 0 which is 00:00:00 on Jan 1, 1970 GMT
  if ($alignFlag)
  {
    $AlignInt=($subsys=~/[yz]/i) ? $interval2 : $interval;
    $BaseTime=0;
  }

  # Point to our alarm handler and set up some u-constants
  $SIG{"ALRM"}=\&sigAlrm;
  $uInterval=$interval*1000000;

  # Now we can enable our alarm and sleep for at least a full interval, from
  # which we'll awake by a 'sigalrm'.  The first time thought is based on our
  # alignment, which may be '$interval2', but after that it's always '$interval'
  # Also note use of arg2 to note first call since arg1 always set to 'ALRM'
  # when it fires normally.
  $uAlignInt=$AlignInt*1000000;
  sigAlrm(undef, 1);
  sleep $AlignInt+1;
  $uAlignInt=$uInterval;
  sigAlrm();    # we're now aligned so reset timer
}

if ($debug & 1 && $options=~/x/i)
{
  $temp=$limBool ? "AND" : "OR";
  print "Exception Processing In Effect -- SVC: $limSVC $temp IOS: $limIOS ".
        "LusKBS: $LimLusKBS LusReints: $LimLusReints\n"
}

# remind user we always wait until second sample before producing results
# if only yY, Z or E or both, we don't wait for the standard interval
$temp=$interval;
$temp=$interval2    if $subsys=~/^[EyYZ]+$/;
$temp=$interval3    if $subsys eq 'E';
print "waiting for $temp second sample...\n"    if $filename eq "";

# Need to make sure proc's and env's align with printing of other vars first 
# time.  In other words, do the first read immediately.
$counted2=$limit2-1    if $subsys=~/[yYZ]/;
$counted3=$limit3-1    if $subsys=~/E/;

print "Subsys: $subsys  SubOpts: $subOpts  Options: $options\n"    if $debug & 1;

# Figure out how many intervals we want to check for lustre config changes,
# noting that in the debugging case where the interval is 0, we calculate it
# based on a day's worth of seconds.
$lustreCheckCounter=0;
$lustreCheckIntervals=($interval!=0) ? 
    int($lustreConfigInt/$interval) : int($count/(86400/$lustreConfigInt));
$lustreCheckIntervals=1    if $lustreCheckIntervals==0;
print "Lustre Check Intervals: $lustreCheckIntervals\n"    if $debug & 2;

# Same thing (sort of) for interconnect interval
$interConnectCounter=0;
$interConnectIntervals=($interval!=0) ? 
    int($InterConnectInt/$interval) : int($count/(86400/$InterConnectInt));
$interConnectIntervals=1    if $interConnectIntervals==0;
print "InterConnect Interval: $interConnectIntervals\n"    if $debug & 2;

if ($options=~/i/)
{
  my $temp=buildCommonHeader(0, undef);
  printText($temp);
}

#    M a i n    P r o c e s s i n g    L o o p

# This is where efficiency really counts
$doneFlag=0;
$firstPass=1;
for (; $count!=0 && !$doneFlag; $count--)
{
  # Use the same value for seconds for the entire cycle
  if ($hiResFlag)
  {
    # we have to fully qualify name because or 'require' vs 'use'
    ($intSeconds, $intUsecs)=Time::HiRes::gettimeofday();
  }
  else
  {
    $intSeconds=time;
    $intUsecs=0;
  }

  #    T i m e    F o r    a    N e w    L o g ?

  # if writing to a logfile and rolling them...
  # note that there is at least one situation where someone wants to 
  # run collectl continuously and catch headers when the date changes,
  # hence the support for executing the log rolling code and generating 
  # headers even when not logging to a file.
  if ($logToFileFlag && $rollSecs)
  {
    # if time to roll, do so and recalculate next roll time.
    if ($intSeconds ge $rollSecs)
    {
      $zlibErrors=0;
      newLog($filename, "", "", "", "", "");
      $rollSecs+=$rollIncr*60;

      # Just like the logic above to calculate the time of our first roll, we
      # need to see if we're going to cross a time change boundary
      if ($rollIncr>60)
      {
        ($sec, $min, $hour, $day, $mon, $year)=localtime($rollSecs);

	#print "EXP: $expectedHour  HOUR: $hour\n";
        my $diff=($expectedHour-$hour);
        $diff=1    if $diff==-23;
        $rollSecs+=$diff*3600;
        $expectedHour+=$rollIncr/60;
        $expectedHour%=24;
        logmsg("I", "Time change!  Did you remember to change your watch?")    if $diff!=0;
      }
      logmsg("I", "Logs rolled");
      initDay();
    }
  }

  #    G a t h e r    S T A T S

  # This is the section of code that needs to be reasonably efficient.
  # but first, start the interval with a time marker noting we have to first
  # make sure we're padding with 0's, then truncate to 2 digit precision.
  $fullTime=sprintf("%d.%06d", $intSeconds, $intUsecs);
  record(1, sprintf(">>> %.3f <<<\n", $fullTime))               if $recFlag0;
  record(1, sprintf(">>> %.3f <<<\n", $fullTime), undef, 1)     if $recFlag1;

  ##############################################################
  #    S t a n d a r d    I n t e r v a l    P r o c e s s i n g
  ##############################################################

  if ($cFlag || $CFlag || $dFlag || $DFlag ||$mFlag)
  {
    # Too crazy to do in getProc() though maybe someday should be moved there
    open PROC, "</proc/stat" or logmsg("F", "Couldn't open '/proc/stat'");
    while ($line=<PROC>)
    {
      last             if $line=~/^kstat/;
      record(2, $line)
	  if (( ($cFlag || $CFlag) && $line=~/^cpu|^ctx|^proce/) ||
              ( ($dFlag || $DFlag) && $kernel2_4 && !$partDataFlag && $line=~/^disk/) ||
	      ( $DFlag && $line=~/^cpu /) ||
              ( $mFlag && $line=~/^page|^swap|^procs/));  # note that 'page/swap' 2.4 and procs in 2.6 and later 2.4s
      record(2, "$1\n")
          if ($cFlag || $CFlag) && $line=~/(^intr \d+)/;
    }
    close PROC;
  }

  # Disk data can come from 'diskstats' OR 'partitions'.  If no data in 
  # partitions and a 2.4 kernel, we'll have gotten it from /proc/stat
  if ($dFlag || $DFlag)
  {
    getProc(9, "/proc/diskstats", "disk")    if $kernel2_6;
    getProc(9, "/proc/partitions", "par", 2) if $kernel2_4 && $partDataFlag;
  }

  if ($cFlag || $CFlag)
  {
    getProc(0, "/proc/loadavg", "load");
  }

  if ($tFlag || $TFlag)
  {
    getProc(15, "/proc/net/netstat", "", 1);
  }

  if ($iFlag)
  {
    getProc(0, "/proc/sys/fs/dentry-state", "fs-ds")      if $dentryFlag;
    getProc(0, "/proc/sys/fs/inode-state",  "fs-is")      if $inodeFlag;
    getProc(0, "/proc/sys/fs/file-nr",      "fs-fnr")     if $filenrFlag;
    getProc(0, "/proc/sys/fs/super-nr",     "fs-snr")     if $supernrFlag;
    getProc(0, "/proc/sys/fs/dquot-nr",     "fs-dqnr")    if $dquotnrFlag;
  }

  if ($lFlag || $LFlag || $LLFlag)
  {
    # Check to see if any services changed and if they did, we may need
    # a new logfile as well.
    if (++$lustreCheckCounter==$lustreCheckIntervals)
    {
      newLog($filename, "", "", "", "", "")
	  if lustreCheckClt()+lustreCheckOst()+lustreCheckMds()>0 && $filename ne '';
      $lustreCheckCounter=0;
    }
    # This data actually applies to both MDS and OSS servers and if
    # both services are running on the same node we're only going to
    # want to collect it once.
    if ($subOpts=~/D/ && ($NumMds || $OstFlag))
    {
      my $diskNum=0;
      foreach my $diskname (@LusDiskNames)
      {
        # Note that for scsi, we read the whole thing and for cciss
        # quit when we see the line with 'index' in it.  Also note that
        # for sfs V2.2 we need to skip more for cciss than sd disks
        $diskSkip=($sfsVersion lt '2.2' || $LusDiskDir=~/sd_iostats/) ? 2 : 14;
        $statfile="$LusDiskDir/$diskname";
        getProc(2, $statfile, "LUS-d_$diskNum", $diskSkip, undef, 'index');
        $diskNum++;
      }
    }

    # OST Processing
    if ($OstFlag)
    {
      # Note we ALWAYS read the base ost data
      for ($ostNum=0; $ostNum<$NumOst; $ostNum++)
      {
        $dirspec="/proc/fs/lustre/obdfilter/$lustreOstSubdirs[$ostNum]";
        getProc(1, "$dirspec/stats", "OST_$ostNum", undef, undef, "^io");

        # for versions of SFS prior to 2.2, there are only 9 buckets of BRW data.
        getProc(2, "$dirspec/brw_stats", "OST-b_$ostNum", 4, $numBrwBuckets)
	  if $subOpts=~/B/;
      }
    }

    # MDS Processing
    if ($NumMds)
    {
      getProc(3, "/proc/fs/lustre/mdt/MDT/mds/stats", "MDS", 22, 21);
    }

    # CLIENT Processing
    if ($CltFlag)
    {
      $fsNum=0;
      foreach $subdir (@lustreCltDirs)
      {
	# For vanilla -sl we only need read/write info, but lets grab 
        # metadata file we're at it.  In the case of -OR, we also want readahead stats
        getProc(11, "/proc/fs/lustre/llite/$subdir/stats", "LLITE:$fsNum", 1, 19);
        getProc(0,  "/proc/fs/lustre/llite/$subdir/read_ahead_stats", "LLITE_RA:$fsNum", 1)
	    if $subOpts=~/R/;
	$fsNum++;
      }

      # RPC stats are optional for both clients and servers
      if ($subOpts=~/B/)
      {
        for ($index=0; $index<$NumLustreCltOsts; $index++)
        {
          getProc(2, "$lustreCltOstDirs[$index]/rpc_stats", "LLITE_RPC:$index", 8, 11);
        }
      }
      # Client LL data
      if ($LLFlag)
      {
        for ($index=0; $index<$NumLustreCltOsts; $index++)
        {
          getProc(12, "$lustreCltOstDirs[$index]/stats", "LLDET:$index ", 7);
        }
      }
    }
  }

  # even if /proc not there (nothing exported/mounted), it could
  # show up later so we need to be sure and look every time
  if ($fFlag || $FFlag)
  {
    getProc(8, $procNfs, "nfs-");
  }

  if ($mFlag)
  {
    if ($kernel2_4)
    {
      getProc(4, "/proc/meminfo", "", 1);
    }
    else
    {
      # In 2.6 kernels things are very different
      getProc(0, "/proc/meminfo", "", undef, undef, '^Vmalloc');
      getProc(0, "/proc/vmstat",  "", 6, 4);
    }
  }

  if ($sFlag)
  {
    getProc(0, "/proc/net/sockstat", "sock");
  }

  if ($nFlag || $NFlag)
  {
    getProc(0, "/proc/net/dev", "Net", 2);
  }

  if ($xFlag || $XFlag)
  {
    # Whenever we hit the end of interconnect checking interval we need to 
    # see if any of them changed configuration (such as an IB port fail-over)
    # NOTE - we do the $filename test last so we ALWAYS do the elan/ib checks
    # even if printing to terminal.
    if (++$interConnectCounter==$interConnectIntervals)
    {
      newLog($filename, "", "", "", "", "")
	  if (($quadricsFlag && elanCheck()) || ($mellanoxFlag && ibCheck()))
	      && $filename ne '';
      $interConnectCounter=0;
    }

    # only if there is indeed quadric stats detected
    if ($quadricsFlag && $NumXRails)
    {
      for ($i=0; $i<$NumXRails; $i++)
      {
        getProc(0, "/proc/qsnet/ep/rail$i/stats", "Elan$i");
      }
    }

    if ($mellanoxFlag && $NumHCAs)
    {
      for ($i=0; $i<$NumHCAs; $i++)
      {
        if ( -e $SysIB ) 
        { 
          if ( -e $PQuery )
	  {
            foreach $j (1..2)
            {
              if ($HCAPorts[$i][$j])  # Make sure it has an active port
              {
		getExec(1, "$PQuery -r $HCALids[$i][$j] $j 0xf000", "ib$i-$j");
	      }
            }
          }
        }
        elsif ( -e $VoltaireStats )
        {
	  # If Voltaire ever supports multiple HCAs, we'll need the 
	  # uncommented code instead
	  getProc(0, $VoltaireStats, 'ib0', 3, 2);
	  #getProc(0, "/proc/voltaire/ib$i/stats", "ib$i", 3, 2);
	}
        else
        {
          # Currently only 1 port is active, but if more are, we need to
          # deal with them
          foreach $j (1..2)
          {
            if ($HCAPorts[$i][$j])  # Make sure it has an active port
            {
              # Grab counters and do an immediate reset of them
              getExec(2, "$PCounter -h $HCAName[$i] -p $j", "ib$i-$j");
	      `$PCounter -h $HCAName[$i] -p $j -s 5 >/dev/null`;
	     }
          }
        }
      }
    }
  }

  #############################################
  #    I n t e r v a l 2    P r o c e s s i n g
  #############################################

  if (($yFlag || $YFlag || $ZFlag) && ++$counted2==$limit2)
  {
    if ($yFlag || $YFlag)
    {
      # NOTE - $SlabGetProc is either 0 for all slabs or 14 for selective
      #        $SlabHeader is 1 for 2.4 kernels and 2 for 2.6 ones
      if ($slabinfoFlag)
      {
        getProc($SlabGetProc, "/proc/slabinfo", "Slab", $SlabSkipHeader);
      }
      else
      {
	# Reading the whole directory and skipping links via the 'skip' hash
        # is only about about 1/2 second slower over the day so let's just do it.
        opendir SLUBDIR, "/sys/slab" or die;
        while ($slab=readdir SLUBDIR)
	{
	  next    if $slab=~/^\./;
	  next    if $slabopts ne '' && !defined($slabdata{$slab});
	  next    if defined($slabskip{$slab});

	  # See if a new slab appeared, noting this doesn't apply when using
          # -Y because of the optimization 'next' for '$slabopts' above
	  # also remember since we're only looking at root slabs, we'll never
          # discover 'linked' ones
	  if (!defined($slabdata{$slab}))
          {
	    $newSlabFlag=1;
	    logmsg("W", "New slab detected: $slab");
  	  }

	  # Whenever there are 'new' slabs to read (which certainly includes the first 
          # full pass or any time we change log files) read constants before reading
          # variant data.
	  getSys('Slab', '/sys/slab', $slab, ['object_size', 'slab_size', 'order','objs_per_slab'])
	      if $firstPass || $newRawFlag || $newSlabFlag;
	  getSys('Slab', '/sys/slab', $slab, ['objects', 'slabs']);
	  $newSlabFlag=0;
	}
      }
    }

    if ($ZFlag)
    {
      # if user chose -OP or -Z with only specific pids, we're only going 
      # to process contents of %pidProc and nothing more so we don't have 
      # to read /proc and we'll save a lot of time.  Also note the pid
      # might have gone away!
      undef %pidSeen;
      if ($pidOnlyFlag)
      {
        foreach $pid (keys %pidProc)
        {
          # When looking at threads, we read ALL data from /proc/pid/task/pid
          # rather than /proc/pid so we can be assured we only seeing runtimes
          # for the main process.  Later on too...
          $task=($ThreadFlag) ? "$pid/task/" : '';

          # note that not everyone has 'Vm' fields in status so we need
	  # special checks.  Also note both here and below whenever we process a pid
          # and not -OP (we could have gotten here via -Zp...) and we're doing threads
	  # on this pid, see if any new threads showed up.  If this gets much more
          # involved it should probably become a sub since we do it below too.
	  $pidSeen{$pid}=getProc(17, "/proc/$task/$pid/stat",    "proc:$pid stat", undef, 1);
	  $pidSeen{$pid}=getProc(13, "/proc/$task/$pid/status",  "proc:$pid")
	      if $pidSeen{$pid}==1;
	  $pidSeen{$pid}=getProc(16, "/proc/$task/$pid/cmdline", "proc:$pid cmd", undef, 1)
	      if $pidSeen{$pid}==1;
	  $pidSeen{$pid}=getProc(17, "/proc/$task/$pid/io", "proc:$pid io")
	      if $pidSeen{$pid}==1 && $processIOFlag;
	  findThreads($pid)    if $ThreadFlag && $subOpts!~/P/ && $pidThreads{$pid};
        }
      }
      else
      {
        opendir DIR, "/proc" or logmsg("F", "Couldn't open /proc");
        while ($pid=readdir(DIR))
        {
          next    if $pid=~/^\./;    # skip . and ..
          next    if $pid!~/^\d/;    # skip not pids
	  next    if defined($pidSkip{$pid});
	  next    if !defined($pidProc{$pid}) && pidNew($pid)==0;

          # see comment in previous block
          $task=($ThreadFlag) ? "$pid/task/" : '';

  	  print "%%% READPID $pid\n"    if $debug & 256;
          $pidSeen{$pid}=getProc(17, "/proc/$task/$pid/stat",    "proc:$pid stat", undef, 1);
          $pidSeen{$pid}=getProc(13, "/proc/$task/$pid/status",  "proc:$pid")
	      if $pidSeen{$pid}==1;
	  $pidSeen{$pid}=getProc(16, "/proc/$task/$pid/cmdline", "proc:$pid cmd", undef, 1)
	      if $pidSeen{$pid}==1;
	  $pidSeen{$pid}=getProc(17, "/proc/$task/$pid/io", "proc:$pid io")
	      if $pidSeen{$pid}==1 && $processIOFlag;
	  findThreads($pid)    if $ThreadFlag && $subOpts!~/P/ && $pidThreads{$pid};
        }
      }

      if ($ThreadFlag)
      {
        foreach $pid (keys %tpidProc)
        {
	  # Location of thread stats is below parent
	  $task="$tpidProc{$pid}/task";

	  # The 'T' lets the processing code know it's a thread for formatting purposes
  	  $tpidSeen{$pid}=getProc(17, "/proc/$task/$pid/stat",   "procT:$pid stat", undef, 1);
	  $tpidSeen{$pid}=getProc(13, "/proc/$task/$pid/status", "procT:$pid")
	      if $tpidSeen{$pid}==1; 
	  $tpidSeen{$pid}=getProc(17, "/proc/$task/$pid/io", "procT:$pid io")
	      if $tpidSeen{$pid}==1 && $processIOFlag;
        }
      }

      # how else will we know if a process exited?
      # This will also clean up stale thread pids as well.
      cleanStalePids();
    }
    $counted2=0;
  }

  #############################################
  #    I n t e r v a l 3    P r o c e s s i n g
  #############################################

  # NOTE - since this currently only works for DL360/380 and may
  # be changing, this may end up being dropped, so let's use types
  # in the 100 range...
  if ($EFlag && ++$counted3==$limit3)
  {
    getProc(100, "/proc/cpqfan",  "fan ",  1);
    getProc(101, "/proc/cpqpwr",  "pwr ",  1);
    getProc(102, "/proc/cpqtemp", "temp ", 1);
    $counted3=0;
  }

  ###########################################################
  #    E n d    O f    I n t e r v a l    P r o c e s s i n g
  ###########################################################

  # if printing to terminal OR generating data in plot format (or both)
  # we need to wait until the end of the interval so complete data is in hand
  if (!$logToFileFlag || $plotFlag || $sexprFlag)
  {
    $fullTime=sprintf("%d.%06d", $intSeconds, $intUsecs);
    intervalEnd(sprintf("%.3f", $fullTime))
  }

  # If -S specified, see if our parent's pid went away and if so, we're done
  last    if $sshFlag && !-e "/proc/$myPpid";

  # if we'll pass the end time while asleep, just get out now.
  last    if $endSecs && ($intSeconds+$interval)>$endSecs;

  # NOTE - I tried used select() as timer when no HiRes but got premature
  # wakeups on early 2.6 testing and so went back to sleep().  Also, in
  # case we lose our wakeup signal, only sleep as long as requested noting
  # we SHOULD get woken up before this timer expires since we already used
  # up part of our interval with data collection
  flushBuffers()                       if !$autoFlush && $flushTime && time>=$flushTime;
  if ($interval!=0)
  {
    sleep $interval                    if !$hiResFlag;
    Time::HiRes::usleep($uInterval)    if  $hiResFlag;
  }
  $firstPass=$newRawFlag=0;
  next;
}

# the only easy way to tell a complete interval is by writing a marker, with
# not time, since we don't need it anyway.
if ($hiResFlag)
{
  ($intSeconds, $intUsecs)=Time::HiRes::gettimeofday();
  $fullTime=sprintf("%d.%06d",  $intSeconds, $intUsecs);
}
else
{
  $fullTime=time;
}
record(1, sprintf(">>> %.3f <<<\n", $fullTime))               if $recFlag0;
record(1, sprintf(">>> %.3f <<<\n", $fullTime), undef, 1)     if $recFlag1;

# close logs cleanly and turn echo back on because in -M1 we turned it off.
closeLogs();
unlink $PidFile    if $daemonFlag;
`stty echo`        if !$PcFlag && $termFlag;
logmsg("I", "Terminating...");
logsys("Terminating...");

sub preprocSwitches
{
  my $switches='';
  foreach $switch (@ARGV)
  {
    # Cleaner to not allow -top and force --top
    error("invalid switch '$switch'.  did you mean -$switch?")
         if $switch=~/^-to/;

    # multichar switches COULD be single char switch and option
    if ($switch=~/^-/ && length($switch)>2)
    {
      $use=substr($switch, 0, 2).' '.substr($switch,2);
      error("invalid switch '$switch'.  did you mean -$switch?  if not use '$use'")
	  if $switch=~/^-al|^-ad|^-be|^-co|-^de|^-de|^-en|^-fl|^-he|^-no|^-in|^-ra/;
      error("invalid switch '$switch'.  did you mean -$switch?  if not use '$use'")
	  if $switch=~/^-li|^-lu|^-me|-^ni|^-op|^-su|^-ro|^-ru|^-ti|^-wi|^-sl|^-pr/;
      $switches.="$switch ";
    }
  }
  return($switches);
}

# This only effects multiple files for the same system on the same day.
# In most cases, those log files will have been run with the same parameters
# and as a result when their output is simply merged into single 'tab' or 
# detail files.  However on rare occasions, the configurations will NOT be the
# same and the purpose of this function is to recognize that and change the
# processing parameters according, if possible.  The best example of this is
# if one generates one log based on -scd and a second on -scm.  By forcing
# the processing of both to be -scdm, the resultant 'tab' file will contain
# everything.  Alas, things get more complicated with detail files and even
# more so with lustre detail files if filesystems are mounted/umounted, etc.
# In any event, the details are in the code...
#
# NOTE - if any files cannot be processed, none will and the user will be
#        require to change command options
sub preprocessPlayback
{
  my $filespec=shift;
  my ($selected, $header, $i);
  my ($lastPrefix, $thisSubSys, $thisSubOpt, $thisInterval, $mergedInterval);
  my ($lastSubSys, $lastSubOpt, $lastNfs, $lastLustreConfig, $lastLustreSubSys);
  my $preprocFlags=0;
  local ($configChange, $filePrefix, $file);

  $selected=0;
  $configChange=0;
  $lastPrefix=$lastLustreConfig=$mergedInterval="";
  while ($file=glob($playback))
  {
    print "Preprocessing: $file\n"    if $debug & 2048;

    # need to do individual file checks in case filespec matches bad files
    if ($file!~/(.*-\d{8})-\d{6}\.raw[p]*/)
    {
      $preprocErrors{$file}="I:its name is wrong format";
      next;
    }
    $filePrefix=$1;

    # skip these, but set a flag to let us know we did
    if ($file=~/\.rawp/)
    {
       $preprocFlags|=1;
       next;
    }

    if (-z $file)
    {
      $preprocErrors{$file}="I:its size is zero";
      next;
    }

    if ($file!~/raw$|gz$/)
    {
      $preprocErrors{$file}="I:it doesn't end in 'raw' or 'gz'";
      next;
    }

    # If any files in 'gz' format, make sure we can cope.
    $zInFlag=0;
    if ($file=~/gz$/ && !$zlibFlag)
    {
      $zInFlag=1;
      $preprocErrors{$file}="E:Zlib not installed";
      next;
    }

    # Read header - cleanup code in newlog: see call to getHeader in newLog()
    $header=getHeader($file);
    $header=~/SubSys:\s+(\S+)/;
    $thisSubSys=$headerSubSys=$1;
    $header=~/SubOpts:\s+(\S*)\s+Options:/;  # could be blank
    $thisSubOpt=$1;
    $header=~/Interval:\s+(\S+)/;
    $thisInterval=$1;

    # If user specified --procio and file doesn't have data, we can't process it
    $flags=($header=~/Flags:\s+(\S+)/) ? $1 : '';
    if ($procioFlag && $flags!~/i/)
    {
      $preprocErrors{$file}="E:--procio requested but data not present in file";
      next;
    }

    # we need to merge intervals is user has selected her own AND set a flag so
    # changeConfig() will update %playbackSettings{} correctly
    if ($userInterval ne '')
    {
      $configChange=4;   # will cause config change processing AND -m notice
      $mergedInterval=mergeIntervals($thisInterval, $mergedInterval);

      # on subsequent files, we need to check for interval consistency
      if ($filePrefix eq $lastPrefix)
      {
        print "Merged Intervals: $mergedInterval\n"    if $debug & 2048;
	my ($int1, $int2, $int3)=   split(/:/, $mergedInterval);
	my ($uint1, $uint2, $uint3)=split(/:/, $userInterval);
        $preprocErrors{$file}="E:common interval '$mergedInterval' not self-consistent"
	    if (defined($int2) && ($int1>$int2 || int($int2/$int1)*$int1!=$int2)) ||
               (defined($int3) && ($int1>$int3 || int($int3/$int1)*$int1!=$int3));

        $preprocErrors{$file}="E:common interval '$mergedInterval' has value(s) > $userInterval"
	    if $uint1<$int1 || 
  	       (defined($uint2) && defined($int2) && $unint2<$int2) ||
	       (defined($uint3) && defined($int3) && $unint3<$int3);

        $preprocErrors{$file}="E:common interval '$mergedInterval' not consistent with $userInterval"
            if (int($uint1/$int1)*$int1!=$uint1) ||
	       (defined($unint2) && defined($int2) && (int($uint2/$int2)*$int2!=$uint2)) ||
  	       (defined($unint3) && defined($int3) && (int($uint3/$int3)*$int3!=$uint3));
      }
    }

    print "File: $file  SubSys: $thisSubSys  SubOpt: $thisSubOpt\n"
	if $debug & 2048;

    # note that -s and -L override anything in the files.
    $thisSubSys=$userSubsys          if $userSubsys ne '';
    $lastLustreConfig=$lustreSvcs    if $lustreSvcs ne '';
    $lastLustreConfig.='|||';

    # The one exception to the rule above is you cannot have conflicts between -sL
    # and -sLL.  It's safest (and easiest) to make as a separate test.
    if ( (($userSubsys=~/LL/ && $headerSubSys=~/^[^L]*L[^L]*$/) ||
	($headerSubSys=~/LL/ && $userSubsys=~/^[^L]*L[^L]*$/)))
    {
        $preprocErrors{$file}="E:it mixes -sL and -sLL with other files of same prefix";
	next;
    }

    # it's only if the prefix for this file is the same as the last that
    # we have to do all our interval merging and consistency checks.
    $selected++;
    if ($filePrefix ne $lastPrefix)
    {
      configChange($lastPrefix, $lastSubSys, $lastLustreConfig, $mergedInterval)
	  if $lastPrefix ne '';

      # New prefix, so initialize for subsequent tests
      $newPrefix=1;
      $configChange=0;
      $mergedInterval='';

      # this returns client/server and version or null string
      $thisNfs=checkNfs("", $thisSubSys, $thisSubOpt);

      ($thisLustreConfig, $thisLustreSubSys)=checkLustre("", $header, "", $thisSubSys);
    }
    else    # subsequent files (if any) for same prefix-date
    {
      # subsystem checks, but only if -s not specified by user
      $newPrefix=0;
      $thisSubSys=checkSubSys($lastSubSys, $thisSubSys)
	  if $userSubsys eq '' && ($thisSubSys ne $lastSubSys);

      $thisNfs=checkNfs($thisNfs, $thisSubSys, $thisSubOpt);

      ($thisLustreConfig, $thisLustreSubSys)=
	  checkLustre($lastLustreConfig, $header, $thisLustreSubSys, $thisSubSys);
    }
    $lastPrefix=$filePrefix;
    $lastSubSys=$thisSubSys;
    $lastLustreConfig=$thisLustreConfig;
  }

  # If multiple files for this prefix processed there are outstanding
  # potential changes we need to check for.
  configChange($lastPrefix, $lastSubSys, $lastLustreConfig, $mergedInterval)
      if $selected && !$newPrefix;
  return($preprocFlags);
}

# This purpose of this routine is to look at the intervals from multiple headers
# and figured out what common intervals would be needed to process them all if the
# user wanted to override them.  In effect determine the 'least commmon interval',
# only I'm not going to be too precise since virtually all the time these files
# WILL have the same intervals and calculating the LCI will be a lot of work.
sub mergeIntervals
{
  my $interval=shift;
  my $merged=  shift;

  my ($mgr1, $mrg2, $mrg3)=split(/:/, $merged);
  my ($int1, $int2, $int3)=split(/:/, $interval);

  # if any intervals aren't in the merged list, simply move them in
  # which will always be the case the first time through
  $mrg1=$int1    if !defined($mrg1) || $mrg1 eq '';
  $mrg2=$int2    if !defined($mrg2) || $mrg2 eq '';
  $mrg3=$int3    if !defined($mrg3) || $mrg3 eq '';

  # get least common intervals, but only if new value defined
  $mrg1=lci($int1, $mrg1);
  $mrg2=lci($int2, $mrg2)    if defined($int2);
  $mrg3=lci($int3, $mrg3)    if defined($int3);

  # return the list of merged intervals
  $merged=$mrg1;
  $merged.=":$mrg2"    if defined($mrg2);
  $merged.=(defined($mrg2)) ? ":$mrg3" : "::$mrg3"    if defined($mrg3);
  return($merged);
}

sub lci
{
  my $new=shift;
  my $old=shift;

  $lci=$old;
  if ($new>$old)
  {
    # if a common multiple, use new interval for lci; other return their product 
    # which will be common but may NOT be the LEAST common!
    $lci=($new==int($new/$old)*$old) ? $new : $old*$new;
  }
  else
  {
    # same thing only see if $old a mulitple of $new
    $lci=($old==int($old/$new)*$new) ? $old : $old*$new;
  }
}

sub configChange
{
  my $prefix=  shift;
  my $subsys=  shift;
  my $config=  shift;
  my $interval=shift;
  my ($services, $mdss, $osts, $clts);
  my ($i, $type, $names, $temp, $index);

  ($services, $mdss, $osts, $clts)=split(/\|/, $config);
  print "configChange() -- Pre: $prefix  Svcs: $services Mds: $mdss Osts: $osts Clts: $clts Int: $interval\n"
      if $debug & 2;

  # Usually there are no existing messages, but we gotta check...
  $index=defined($preprocMessages{$prefix}) ? $preprocMessages{$prefix} : 0;
  if ($configChange)
  {
    $preprocMessages{$prefix.'|'.$index++}="  -s overridden to '$subsys'"
	if $configChange & 1;
    $preprocMessages{$prefix.'|'.$index++}="  -L overridden to '$services'"
	if $configChange & 2;
    $preprocMessages{$prefix.'|'.$index++}="  -i overridden from '$interval' to '$userInterval'"
	if $configChange & 4;

    foreach $i (8,16,32)
    {
      next    if !($configChange & $i);
      if ($i==8)  { $types=$mdss; $temp="MDS"; }
      if ($i==16) { $types=$osts; $temp="OST"; }
      if ($i==32) { $types=$clts; $temp="Client"; }
      $preprocMessages{$prefix.'|'.$index++}="  combined Lustre $temp objects now '$types'";
    }
    $preprocMessages{$prefix}=$index;
    $playbackSettings{$prefix}="$subsys|$services|$mdss|$osts|$clts|$interval";
    print "Playback -- Prefix: $prefix  Settings: $playbackSettings{$prefix}\n"    if $debug & 2048;
  }

  # Send these to log if we're not running interactively and -m not specified
  for ($i=0; !$termFlag && !$msgFlag && $i<$index; $i++)
  {
    logmsg("W", $preprocMessages{$prefix.'|'.$i});
  }
  return;
}

sub checkSubSys
{
  my $lastSubSys=shift;
  my $thisSubSys=shift;
  my ($nextSubSys, $i);

  print "Check SubSys -- Last: $lastSubSys  This: $thisSubSys\n"
      if $debug & 2048;

  for ($i=0; $i<length($thisSubSys); $i++)
  {
    $temp=substr($thisSubSys, $i, 1);
    if ($lastSubSys!~/$temp/)
    {
      $lastSubSys.=$temp;
      $configChange|=1;
    }
  }

  $preprocErrors{$file}="E:-P and details to terminal not allowed"
      if $lastSubSys=~/[A-Z]/ && $filename eq '' && $plotFlag;
 
  return($lastSubSys);  # has new sub-systems appended
}

sub checkSubOpts
{
  # sub-options
  error("invalid sub-option")                     if $subOpts ne '' && $subOpts!~/[23BCDMLPRcom]/;
  error("-O$1 only applies to slabs")             if $subOpts=~/([sS])/ && $subsys!~/Y/i;
  error("-OP only applies to processes")          if $subOpts=~/P/ && $subsys!~/Z/;
  error("-OC only supported with -s f/F")         if $subOpts=~/C/ && $subsys!~/f/i;

  # it's possible this is not recognized as running a particular type of service
  # from the 'flag's if that service is isn't yet started and so we need
  # to check $lustreSvcs too.  It's just easier to do it this way...
  my $cltFlag=($CltFlag || $lustreSvcs=~/c/) ? 1 : 0;
  my $mdsFlag=($MdsFlag || $lustreSvcs=~/m/) ? 1 : 0;
  my $ostFlag=($OstFlag || $lustreSvcs=~/o/) ? 1 : 0;

  # These are lustre only
  error("-Oc only applies to Lustre Clts")        if $subOpts=~/c/ && !$cltFlag;
  error("-Oo only applies to Lustre OSTs")        if $subOpts=~/o/ && !$ostFlag;
  error("-Om only applies to Lustre MDSs")        if $subOpts=~/m/ && !$mdsFlag;
  error("-OB only applies to Lustre Clts/Osts")   if $subOpts=~/B/ && $ostFlag==0 && $cltFlag==0;
  error("-OB for client details requires -sLL")   if $subOpts=~/B/ && $subsys=~/L/ && $subsys!~/LL/ && $cltFlag;
  error("-OD only applies to Lustre OSTs/MDSs")   if $subOpts=~/D/ && $ostFlag==0 && $mdsFlag==0;
  error("-OM only applies to Lustre Clients")     if $subOpts=~/M/ && !$cltFlag;
  error("-OM does not apply to -sLL")             if $subOpts=~/M/ && $subsys=~/LL/;
  error("-OR only applies to Lustre Clients")     if $subOpts=~/R/ && $cltFlag==0;
  error("-OR does not apply to -sLL")             if $subOpts=~/R/ && $subsys=~/LL/;

  $subOpts.='3'    if $subsys=~/f/i && $subOpts!~/[23]/;
}

sub checkNfs
{
  my $lastNfs=shift;
  my $subsys= shift;
  my $subopt= shift;
  my $temp;

  print "checkNfs(): LastNfs: $lastNfs  SubSys: $subsys  SubOPT: $subopt\n"
      if $debug & 2048;

  $temp='';
  if ($subsys=~/f/i)
  {
    $temp= ($subopt=~/C/) ? 'C' : 'S';
    $temp.=($subopt=~/2/) ? '2' : '3';
  }

  # all these are legal
  return($temp)       if $lastNfs eq '';
  return($lastNfs)    if $temp eq '';
  return($lastNfs)    if $lastNfs eq $temp;  # neither null, both MUST match

  # too tricky to handle all possible inconsistencies with multiple files
  # so we're only going to print a stock message
  $preprocErrors{$filePrefix}="E:confilicting nfs settings with other files of same prefix";
  return($temp);  
}

sub checkLustre
{
  my $lastConfig=shift;
  my $header=    shift;
  my $lastSubSys=shift;
  my $thisSubSys=shift;
  my ($temp, $thisConfig, $thisMdss, $thisOsts, $thisClts);
  my ($tempSubSys, $services, $mdss, $osts, $clts);

  print "checkLustre() -- LastConfig: $lastConfig  LastSubsys: $lastSubSys  ThisSubSys: $thisSubSys\n"
      if $debug & 2048;

  ($services, $mdss, $osts, $clts)=split(/\|/, $lastConfig);
  $services=$osts=$mdss=$clts=''    if $lastConfig eq '';   # first time through

  #    F i r s t    C h e c k    L u s t r e    S e r v i c e s

  # Remember, if set -L trumps everything!
  if ($lustreSvcs eq '')
  {
    $thisConfig='';
    if ($header=~/MdsNames:\s+(.*)\s*NumOst:\s+\d+\s+OstNames:\s+([^\n\r]*)$/m)
    {
      # for the first file of a new prefix, we just use the current mdss/osts
      # and only check for changes on subsequent calls
      if ($1 ne '')
      {
        $thisMdss=$1;
        $thisConfig.='m';
        $mdss=($lastConfig eq '') ? $thisMdss : setNames(4, $thisMdss, $mdss);
      }
      if ($2 ne '')
      {
        $thisOsts=$2;
        $thisConfig.='o';
        $osts=($lastConfig eq '') ? $thisOsts : setNames(8, $thisOsts, $osts);
      }
    }

    if ($header=~/CltInfo:\s+(.*)$/m)
    {
      $thisClts=$1;
      $thisConfig.='c';
      $clts=($lastConfig eq '') ? $thisClts : setNames(16, $thisClts, $clts);
    }

    # see if anything new in config
    for ($i=0; $i<length($thisConfig); $i++)
    {
      $temp=substr($thisConfig, $i, 1);
      if ($services!~/$temp/)
      {
	$services.=$temp;
	$configChange|=2    if $lastConfig ne '';    # only tell user if not first time for this prefix
      }
    }
  }
  else
  {
    $services=$lustreSvcs;
  }

  #    F i n a l l y    S e e    I f    ' L L '

  # ...but only if -s not specified
  if ($subsys eq '')
  {
    $thisSubSys=~/(L+)/;
    $thisSubSys=defined($1) ? $1 : '';

    # This one is really pretty rare but we gotta check it...
    if ($lastSubSys ne $thisSubSys)
    {
      $preprocErrors{$file}="E:mixing -sL and -sLL with other files of same prefix"
	  if $lastSubSys ne '' && $thisSubSys ne '';
    }
    else
    {
      $lastSubSys=$thisSubSys    if $lastSubSys eq '';
    }
  }

  return(("$services|$mdss|$osts|$clts", $lastSubSys));
}

sub setNames
{
  my $type=    shift;
  my $newNames=shift;
  my $oldNames=shift;
  my $name;

  print "SET NAME -- Type: $type Old: $oldNames  New: $newNames\n"
      if $debug & 2;

  # remember, it's ok for names to go away.  we just want new ones!
  $oldNames=" $oldNames ";    # to make pattern match work
  foreach $name (split(/\s+/, $newNames))
  {
    if ($oldNames!~/ $name /)
    {
      $oldNames.="$name ";
      $configChange|=$type;
    }
  }
  $oldNames=~s/^\s+|\s+$//g;    # trim leading/trailing space
  return($oldNames);
}

# This routine reads partial files AND has /proc specific processing
# code for optimal performance.
sub getProc
{
  my $type=  shift;
  my $proc=  shift;
  my $tag=   shift;
  my $ignore=shift;
  my $quit=  shift;
  my $last=  shift;
  my ($i, $index, $line, $ignoreString);

  if (!open PROC, "<$proc")
  {
    # but just report it once
    logmsg("E", "Couldn't open '$proc'")
	if !defined($notOpened{$proc});
    $notOpened{$proc}=1;
    return(0);
  }

  # Skip beginning if told to do so
  $ignore=0    if !defined($ignore);
  $quit=(defined($quit)) ? $ignore+$quit : 10000;
  for ($i=0; $i<$ignore; $i++)  { <PROC>; }

  $index=0;
  for ($i=$ignore; $i<$quit; $i++)
  {
    last    if !($line=<PROC>);
    last    if defined($last) && $line=~/$last/;

    # GENERIC - just prepend tag to records
    if ($type==0)
    {
      $spacer=$tag ne '' ? ' ' : '';
      record(2, "$tag$spacer$line");
      next;
    }

    # OST stats
    if ($type==1)
    {
      if ($line=~/^read/)  { record(2, "$tag $line"); next; }
      if ($line=~/^write/) { record(2, "$tag $line"); next; }
    }

    # Client RPC and OST brw_stats AND mds/oss disk stats
    elsif ($type==2)
    {
      # for RPC and brw_stats, this block is virtually always 11 entries, 
      # but the first time an OST is created it's not so we have to stop 
      # when we hit a blank.  In the case of disk stats, we call with 
      # $last so it quites on the 'totals' row
      last    if $line=~/^\s+$/;
      record(2, "$tag:$index $line");
      $index++;
    }

    # MDS stats
    elsif ($type==3)
    {
      if ($line=~/^mds_sync/)      { record(2, "$tag $line"); next; }
      if ($line=~/^mds_close/)     { record(2, "$tag $line"); next; }
      if ($line=~/^mds_getattr\s/) { record(2, "$tag $line"); next; }
      if ($line=~/^mds_reint/)     { record(2, "$tag $line"); next; }
    }

    # /proc/meminfo 2.4 kernel
    elsif ($type==4)
    {
      if ($line=~/^Mem:/)    { record(2, "$line"); next; }
      if ($line=~/^Cached:/) { record(2, "$line"); next; }
      if ($line=~/^Swap:/)   { record(2, "$line"); next; }
      if ($line=~/^Active:/) { record(2, "$line"); next; }
      if ($line=~/^Inact/)   { record(2, "$line"); next; }
    }

    # /proc/meminfo 2.6 kernel
    elsif ($type==5)
    {
      if ($line=~/^Mem/)    { record(2, "$line"); next; }
      if ($line=~/^Buf/)    { record(2, "$line"); next; }
      if ($line=~/^Cached/) { record(2, "$line"); next; }
      if ($line=~/^Swap/)   { record(2, "$line"); next; }
      if ($line=~/^Act/)    { record(2, "$line"); next; }
      if ($line=~/^Inact/)  { record(2, "$line"); next; }
      if ($line=~/^Dirtt/)  { record(2, "$line"); next; }
    }

    # NFS
    elsif ($type==8)
    {
      if ($line=~/^rpc/)                    { record(2, "$tag$line"); next; }
      if ($subOpts!~/C/ && $line=~/^net/)   { record(2, "$tag$line"); next; }
      if ($subOpts=~/2/ && $line=~/^proc2/) { record(2, "$tag$line"); next; }
      if ($subOpts=~/3/ && $line=~/^proc3/) { record(2, "$tag$line"); next; }
    }

    # /proc/diskstats & /proc/partitions
    # would be nice if we could improve even more since this table can
    # get quite large.  Note the pattern for cciss MUST match that used
    # in formatit.ph!!!
    elsif ($type==9)
    {
      if ($line=~/cciss\/c\d+d\d+ /)   { record(2, "$tag $line"); next; }
      if ($line=~/hd[ab] /)            { record(2, "$tag $line"); next; }
      if ($line=~/sd[a-z]+ /)          { record(2, "$tag $line"); next; }
      if ($line=~/dm-\d+ /)            { record(2, "$tag $line"); next; }
    }

    # /proc/fs/lustre/llite/fsX/stats
    elsif ($type==11)
    {
      if ($line=~/^dirty/)      { record(2, "$tag $line"); next; }
      if ($line=~/^read/)       { record(2, "$tag $line"); next; }
      if ($line=~/^write_/)     { record(2, "$tag $line"); next; }
      if ($line=~/^open/)       { record(2, "$tag $line"); next; }
      if ($line=~/^close/)      { record(2, "$tag $line"); next; }
      if ($line=~/^seek/)       { record(2, "$tag $line"); next; }
      if ($line=~/^fsync/)      { record(2, "$tag $line"); next; }
      if ($line=~/^getattr/)    { record(2, "$tag $line"); next; }
      if ($line=~/^setattr/)    { record(2, "$tag $line"); next; }
    }

    # /proc/fs/lustre/osc/XX/stats
    # since I've seen difference instances of SFS report these in different
    # locations we have to hunt them out, quitting after 'write' or course.
    elsif ($type==12)
    {
      if ($line=~/^ost_read/)   { record(2, "$tag $line"); next; }
      if ($line=~/^ost_write/)  { record(2, "$tag $line"); last; }
    }

    # /proc/*/status
    elsif ($type==13)
    {
      if ($line=~/^Uid/)        { record(2, "$tag $line", undef, 1); next; }
      if ($line=~/^Vm/)
      { 
	record(2, "$tag $line", undef, 1);
	last    if $line=~/^VmLib/;  # stop reading when we hit last VM variable
	next; 
      }
    }

    # /proc/slabinfo - only if not doing all of them
    elsif ($type==14)
    {
      $slab=(split(/ /, $line))[0];
      record(2, "$tag $line")    if defined($slabProc{$slab});
    }

    # /proc/dev/netstat
    elsif ($type==15)
    {
      # at least on debian 2.6, the first line is blank and the SECOND is
      # the header which we need to skip.
      next    if $line=~/^TcpExt: S/;
      record(2, "$line");
      next;
    }

    # /proc/pid/cmdline - only 1 line long
    elsif ($type==16)
    {
      $line=~s/\000/ /g;
      record(2, "$tag $line\n", undef, 1);
      last;
    }

    # identical to type 0, only it writes to process raw file
    elsif ($type==17)
    {
      $spacer=$tag ne '' ? ' ' : '';
      record(2, "$tag$spacer$line", undef, 1);
      next;
    }

    elsif ($type==100)   # cpqfan
    {
      chomp $line;
      $a=substr($line, 0, 2);
      $b=substr($line, 33, 10);
      $c=substr($line, 52, 12);
      $line="$a $b $c\n";
      record(2, "$tag$line");
    }
    elsif ($type==101)   # cpqpwr
    {
      $a=substr($line, 0, 2);
      $b=substr($line, 33, 10);
      $line="$a $b\n";
      record(2, "$tag$line");
    }
    elsif ($type==102)   # cpqtemp
    {
      $a=substr($line, 0, 2);
      $b=substr($line, 42, 3);
      $line="$a $b\n";
      record(2, "$tag$line");
    }
  }
  close PROC;
  return(1);
}

# Functionally equivilent to getProc(), but instead has to run a command rather
# than look in proc.
sub getExec
{
  my $type=   shift;
  my $command=shift;
  my $tag=    shift;
  print "Type: $type Exec: $command\n"    if $debug & 256;

  # If we can't exec command, only report it once.
  if (!open CMD, "$command|")
  {
    logmsg("W", "Couldn't execute '$command'")
      if !defined($notExec[$type]);
    $notExec[$type]=1;
    return;
  }

  # Open Fabric
  my $oneline='';
  if ($type==1)
  {
    foreach my $line (<CMD>)
    {
      if ($line=~/^#.*(\d+)$/)
      {
        # The 0 is a place holder we don't care about, at least not now
        $oneLine="$1 0 ";
        next;
      }

      # Since we're not doing anything with hex values this will not include
      # the leading 0x, but it will be faster than trying to include it.
      $line=~/([0x]*\d+$)/; 
      $oneLine.="$1 ";
    }
  }

  # Voltaire
  elsif ($type==2)
  {
    foreach my $line (<CMD>)
    {
      if ($line=~/^PORT=(\d+)$/)
      {
	  $oneLine="$1 ";
	  next;
      }

      # If counter, append to list.  Not the funky patter match that will catch
      # both decimal and hex numbers.
	$oneLine.="$1 "    if $line=~/\s(\S*\d)$/;
    }
  }

  # For now, both types return the same thing
  $oneLine=~s/ $//;
  record(2, "$tag: $oneLine\n");
}

# This guy is in charge of reading single valued entries, which are
# typical of those found in /sys.  The other big difference between
# this and getProc() is it doens't have to deal with all those 
# special 'skip', 'ignore', etc flags.  Just read the data!
sub getSys
{
  my $tag=  shift;
  my $sys=  shift;
  my $dir=  shift;
  my $files=shift;

  foreach my $file (@$files)
  {
    # as of writing this for slub, I'm not expecting file open failures
    # but might as well put in here in case needed in the future
    $filename="$sys/$dir/$file";
    if (!open SYS, "<$filename")
    {
      # but just report it once
      logmsg("E", "Couldn't open '$filename'")
	  if !defined($notOpened{$filename});
      $notOpened{$filename}=1;
      return(0);
    }

    my $line=<SYS>;
    record(2, "$tag $dir $file $line");
  }
}

sub record
{
  my $type=    shift;
  my $data=    shift;
  my $recMode= shift;    # error recovery mode
  my $rawpFlag=shift;    # if defined, write to rawp or zrawp

  # This essentially replaces -H in that it let's us see everything read
  # from /proc.  Combine with -d32 to prevent any other output.
  print "$data"     if $debug & 4;

  #    W r i t e    T o    R A W    F i l e

  # a few words about writing to the raw gz file...  If we fail, we need to
  # create a new file and I want to use newLog() since there's a lot going
  # one.  However, part of newLog() writes the commonHeader as well and that
  # in turn calls this routine, so...  We pass a flag around indicating we're 
  # in recovery mode and if writing the common header fails, we have no 
  # alternative other than to abort.

  # when logging raw data to a file $data, the data to write is either an
  # interval marker or raw data.  Note that when doing plot format to a file
  # as well as any terminal based I/O, that all gets handled by dataAnalyze().
  if ($logToFileFlag && $rawFlag)
  {
    if ($zlibFlag)
    {
      # When flags set, we write 'process' data (identified by '$recFlag1') to a 'rawp' 
      # file; otherwise just 'raw'
      my $rawComp=(defined($rawpFlag) && $recFlag1) ? $ZRAWP : $ZRAW;
      $status=$rawComp->gzwrite($data);
      if (!$status)
      {
        $zlibErrors++;
	$temp=$recMode ? 'F' : 'E';
	logmsg($temp, "Error writing to raw.gz file: $rawComp->gzerror()");
        logmsg("F", "Max Zlib error count exceeded")    if $zlibErrors>$MaxZlibErrors;
	newLog($filename, "", "", "", "", "", 1);
        record(1, sprintf(">>> %.3f <<<\n", $fullTime))               if $recFlag0;
        record(1, sprintf(">>> %.3f <<<\n", $fullTime), undef, 1)     if $recFlag1;
      }
    }
    else
    {
      # Same logic as for compressed data above.
      my $rawNorm=(defined($rawpFlag) && $recFlag1) ? $RAWP : $RAW;
      printf $rawNorm $data;
    }
  }

  #    G e n e r a t e    N u m b e r s    F r o m    D a t a

  # When doing interative reporting OR generating plot data, we need to 
  # analyze each record as it goes by.  This means that in the case of '-P --rawtoo'
  # we write to the raw file AND generate the numbers.  Also remember that in the 
  # case of --sexpr we may not end up writing anywhere other than the 'sexpr' itself
  dataAnalyze($subsys, $data)   if $type==2 && (!$logToFileFlag || $plotFlag || $sexprFlag);
}

sub newLog
{
  my $filename=shift;
  my $recDate= shift;
  my $recTime= shift;
  my $recSecs= shift;
  my $recTZ=   shift;
  my $playback=shift;
  my $recMode= shift;    # only used during error recovery mode

  my ($ss, $mm, $hh, $mday, $mon, $year, $datetime);
  my ($dirname, $basename, $command, $fullname, $mode);
  my (@disks, $dev, $numDisks, $i, $oldHeader, $oldSubsys, $timesecs, $timezone);

  if ($recDate eq '')
  {
    # We need EXACT seconds associated with the timestamp of the filename.
    $timesecs=time;
    ($ss, $mm, $hh, $mday, $mon, $year)=localtime($timesecs);
    $datetime=sprintf("%d%02d%02d-%02d%02d%02d", 
		      $year+1900, $mon+1, $mday, $hh, $mm, $ss);
    $dateonly=substr($datetime, 0, 8);
    $timezone=$LocalTimeZone;
  }
  else
  {
    $timesecs=$recSecs;
    $datetime="$recDate-$recTime";
    $dateonly=$recDate;
    $timezone=$recTZ;
  }

  # Build a common header for ALL files, noting type1 for process
  # we only build it if we need it.
  $temp="# Date:       $datetime  Secs: $timesecs TZ: $timezone\n";
  $commonHeader= buildCommonHeader(0, $temp);
  $commonHeader1=buildCommonHeader(1, $temp)    if $recFlag1;

  # Now build a slab subheader just to be used for 'raw' and 'slb' files
  if ($slubinfoFlag)
  {
    $slubHeader="#SLUB DATA\n";
    foreach my $slab (sort keys %slabdata)
    {
      # when we have a slab with no aliases, 'first' gets set to that same
      # name which in turns ends up on the alias list because it always
      # contains 'first' followed by any additional aliases.  On the rare
      # case we have no alias, which can happen where we have only the root
      # slab itself, set the aliases to that slab which will then be skipped.
      my $aliaslist=$slabdata{$slab}->{aliaslist};
      next    if defined($aliaslist) && $slab eq $aliaslist;

      $aliaslist=$slab    if !defined($aliaslist);
      $slubHeader.="#$slab $aliaslist\n";
    }
    $slubHeader.=sprintf("%s\n", '#'x80);
  }

  # If generating plot data on terminal, just open everything on STDOUT
  # but be SURE set the buffers to flush in case anyone runs as part
  # of a script and needs the output immediately.
  if ($filename eq "" && ($plotFlag || $showPHeaderFlag))
  {
    # sigh...
    error("Cannot use -P for terminal output of process and 'other' data at the same time")
	if $subsys=~/Z/ && length($subsys)>1;

    # in the event that someone runs this as a piped command from 
    # a script and turns off headers things lock up unless these 
    # files are set to auto-flush.
    $zFlag=0;
    open $LOG, ">-" or logmsg("F", "Couldn't open LOG for STDOUT"); select $LOG; $|=1;
    open BLK, ">-" or logmsg("F", "Couldn't open BLK for STDOUT"); select BLK; $|=1;
    open CLT, ">-" or logmsg("F", "Couldn't open CLT for STDOUT"); select CLT; $|=1;
    open CPU, ">-" or logmsg("F", "Couldn't open CPU for STDOUT"); select CPU; $|=1;
    open DSK, ">-" or logmsg("F", "Couldn't open DSK for STDOUT"); select DSK; $|=1;
    open ELN, ">-" or logmsg("F", "Couldn't open ELN for STDOUT"); select ELN; $|=1;
    open ENV, ">-" or logmsg("F", "Couldn't open ENV for STDOUT"); select ENV; $|=1;
    open IB,  ">-" or logmsg("F", "Couldn't open IB for STDOUT");  select IB;  $|=1;
    open NFS, ">-" or logmsg("F", "Couldn't open NFS for STDOUT"); select NFS; $|=1;
    open NET, ">-" or logmsg("F", "Couldn't open NET for STDOUT"); select NET; $|=1;
    open OST, ">-" or logmsg("F", "Couldn't open OST for STDOUT"); select OST; $|=1;
    open TCP, ">-" or logmsg("F", "Couldn't open TCP for STDOUT"); select TCP; $|=1;
    open SLB, ">-" or logmsg("F", "Couldn't open SLB for STDOUT"); select SLB; $|=1;
    open PRC, ">-" or logmsg("F", "Couldn't open PRC for STDOUT"); select PRC; $|=1;
    select STDOUT; $|=1;
    return 1;
  }

  #    C r e a t e    N e w    L o g

  # note the way we build files:
  # - if name is a dir, the filename starts with hostname.  
  # - if name not a dir, the filename gets '-host' appended
  # - if raw file it also gets date/time but if plot file only date.
  $filename= "."         if $filename eq '';  # -P and no -f
  $filename.=(-d $filename || $filename=~/\/$/) ? "/$Host" : "-$Host";
  $filename.=(!$plotFlag || $options=~/u/) ? "-$datetime" : "-$dateonly";

  # if the directory doesn't exist (we don't need date/time stamp), create it
  $temp=dirname($filename);
  if (!-e $temp)
  {
    logmsg('W', "Creating directory '$temp'");
    `mkdir $temp`;
  }

  # track number of times same file processed, primarily for options 'a/c'.  in
  # case mulitiple raw files for same day, only check on initial one
  # If we're in playback mode and writing a plotfile, either the user specified
  # an option of 'a', 'c' or 'u', we just created it (newFiles{} defined) OR it had 
  # better not exist!  If is does, return it name so a contextual error message
  # can be generated.
  return $filename    if $playback ne "" && 
                         $options!~/a|c|u/ && 
                         !defined($newFiles{$filename}) &&
			 plotFileExists($filename);

  # -ou is special in that we're never going to have muliple source files generate
  # the same output file so 'a' doesn't mean anything in this context.  Furthermore
  # if the output file already exists and its update time is less than that of the
  # source file, the source file has changed since the output file was created and
  # it should and will be overwritten.  Finally, the user may also have chosen to
  # reprocess a source file with different options and so if 'c' is included the
  # file WILL be overwritten even if newer.  Whew...
  if ($options=~/u/ && plotFileExists($filename))
  {
    my @files;
    @files=glob("$filename*");
    my $plotTime=(stat($files[0]))[9];
    my $rawTime= (stat($playback))[9];
    return($filename)    if $plotTime>$rawTime && $options!~/c/;
  }

  # When writing data in plot format the output file is not time oriented 
  # (unless -ou) so we always write to the same file.  If the 'create' option 
  # is set OR we're in 'u' mode, we do the first open in 'w' mode.
  $newFiles{$filename}++;
  if ($options=~/c|u/ && $newFiles{$filename}==1)
  {
    $mode=">";
    $zmode="wb";
  }
  else
  {
    $mode=">>";
    $zmode="ab";
  }
  print "NewLog Modes: $mode + $zmode Name: $filename\n"    if $debug & 1;

  #    C r e a t e    R A W    F i l e

  if ($rawFlag)
  {
    # When using --rawtoo, the default filename only has a datestamp (unless -ou also
    # specified and so we need to change it back!)
    my $rawFilename=$filename;
    $rawFilename=~s/$dateonly/$datetime/    if $rawtooFlag && $options!~/u/;
    print "Create raw rile:   $rawFilename\n"    if $debug & 8192;

    # Unlike plot files, we ALWAYS compress when compression lib exists
    $ZRAW=Compress::Zlib::gzopen("$rawFilename.raw.gz", $zmode) or
        logmsg("F", "Couldn't open '$rawFilename.raw.gz'")       if $zlibFlag && $recFlag0;
    $ZRAWP=Compress::Zlib::gzopen("$rawFilename.rawp.gz", $zmode) or
        logmsg("F", "Couldn't open '$rawFilename.rawp.gz'")      if $zlibFlag && $recFlag1;
    open $RAW, "$mode$rawFilename.raw"  or
        logmsg("F", "Couldn't open '$rawFilename.raw'")          if !$zlibFlag && $recFlag0;
    open $RAWP, "$mode$rawFilename.rawp"  or
        logmsg("F", "Couldn't open '$rawFilename.rawp'")         if !$zlibFlag && $recFlag1;

    # write common header to raw file (record() ignores otherwise).  Note that we
    # we need to pass along the recovery mode flag because if this record()
    # fails it's fatal.  we may also need a slub header
    record(1, $commonHeader, $recMode)        if $recFlag0;
    record(1, $commonHeader1, $recMode, 1)    if $recFlag1;
    record(1, $slubHeader, $recMode)          if $slubinfoFlag && $subsys=~/y/i;
    $newRawFlag=1;
  }

  #    C r e a t e    P l o t    F i l e s

  if ($plotFlag)
  {
    print "Create plot files: $filename.*\n"    if $debug & 8192;

    # Open 'tab' file in plot mode if processing at least 1 core variable (or extended core)
    $temp="$SubsysCore$SubsysExcore";
    if ($subsys=~/[$temp]/)
    {
      $ZLOG=Compress::Zlib::gzopen("$filename.tab.gz", $zmode) or
	logmsg("F", "Couldn't open '$filename.tab.gz'")       if $zFlag;
      open $LOG, "$mode$filename.tab"  or
	logmsg("F", "Couldn't open '$filename.tab'")          if !$zFlag;
      $headersPrinted=$headersPrintedProc=0;
    }

    print "Writing file(s): $mode$filename\n"    if $msgFlag && !$daemonFlag;
    print "Subsys: $subsys\n"    if $debug & 1;

    open BLK, "$mode$filename.blk" or 
	  logmsg("F", "Couldn't open '$filename.blk'")   if !$zFlag && ($LFlag || $LLFlag) && $subOpts=~/D/;
    $ZBLK=Compress::Zlib::gzopen("$filename.blk.gz", $zmode) or
  	  logmsg("F", "Couldn't open BLK gzip file")     if  $zFlag && ($LFlag || $LLFlag) && $subOpts=~/D/;

    open CPU, "$mode$filename.cpu" or 
	  logmsg("F", "Couldn't open '$filename.cpu'")   if !$zFlag && $CFlag;
    $ZCPU=Compress::Zlib::gzopen("$filename.cpu.gz", $zmode) or
	  logmsg("F", "Couldn't open CPU gzip file")     if  $zFlag && $CFlag;

    open CLT, "$mode$filename.clt" or 
	  logmsg("F", "Couldn't open '$filename.clt'")   if !$zFlag && ($LFlag || $LLFlag) && $reportCltFlag;
    $ZCLT=Compress::Zlib::gzopen("$filename.clt.gz", $zmode) or
	  logmsg("F", "Couldn't open CLT gzip file")     if  $zFlag && ($LFlag || $LLFlag) && $reportCltFlag;

    # if only doing exceptions, we don't need this file.
    if ($options!~/x/)
    {
      open DSK, "$mode$filename.dsk" or 
	  logmsg("F", "Couldn't open '$filename.dsk'")   if !$zFlag && $DFlag;
      $ZDSK=Compress::Zlib::gzopen("$filename.dsk.gz", $zmode) or
	  logmsg("F", "Couldn't open DSK gzip file")     if  $zFlag && $DFlag;
    }

    # exception processing for both x and X options
    if ($options=~/x/i)
    {
      open DSKX, "$mode$filename.dskX" or 
	  logmsg("F", "Couldn't open '$filename.dskX'")   if !$zFlag && $DFlag;
      $ZDSKX=Compress::Zlib::gzopen("$filename.dskX.gz", $zmode) or
	  logmsg("F", "Couldn't open DSKX gzip file")     if  $zFlag && $DFlag;
    }

    if ($XFlag && $NumXRails)
    {
      open ELN, "$mode$filename.eln" or 
	  logmsg("F", "Couldn't open '$filename.eln'")   if !$zFlag;
      $ZELN=Compress::Zlib::gzopen("$filename.eln.gz", $zmode) or
          logmsg("F", "Couldn't open ELN gzip file")     if  $zFlag;
    }

    if ($XFlag && $NumHCAs)
    {
      open IB, "$mode$filename.ib" or 
	  logmsg("F", "Couldn't open '$filename.ib'")   if !$zFlag;
      $ZIB=Compress::Zlib::gzopen("$filename.ib.gz", $zmode) or
          logmsg("F", "Couldn't open IB gzip file")     if  $zFlag;
    }

    open ENV, "$mode$filename.env" or 
	  logmsg("F", "Couldn't open '$filename.env'")   if !$zFlag && $EFlag;
    $ZENV=Compress::Zlib::gzopen("$filename.env.gz", $zmode) or
          logmsg("F", "Couldn't open ENV gzip file")     if  $zFlag && $EFlag;

    open NFS, "$mode$filename.nfs" or 
	  logmsg("F", "Couldn't open '$filename.nfs'")   if !$zFlag && $FFlag;
    $ZNFS=Compress::Zlib::gzopen("$filename.nfs.gz", $zmode) or
          logmsg("F", "Couldn't open NFS gzip file")     if  $zFlag && $FFlag;

    open NET, "$mode$filename.net" or 
	  logmsg("F", "Couldn't open '$filename.net'")   if !$zFlag && $NFlag;
    $ZNET=Compress::Zlib::gzopen("$filename.net.gz", $zmode) or
          logmsg("F", "Couldn't open NET gzip file")     if  $zFlag && $NFlag;

    open OST, "$mode$filename.ost" or 
	  logmsg("F", "Couldn't open '$filename.ost'")   if !$zFlag && ($LFlag || $LLFlag) && $reportOstFlag;
    $ZOST=Compress::Zlib::gzopen("$filename.ost.gz", $zmode) or
          logmsg("F", "Couldn't open OST gzip file")     if  $zFlag && ($LFlag || $LLFlag) && $reportOstFlag;

    # These next  guys are special because they're not really detail files per se, 
    # Furthermore, if --rawtoo we don't create proc/slab files
    if (!$rawtooFlag)
    {
      print "Creating PRC and/or SLB\n"    if $debug & 8192;
      open PRC, "$mode$filename.prc" or 
	  logmsg("F", "Couldn't open '$filename.prc'")  if !$zFlag && $ZFlag;
      $ZPRC=Compress::Zlib::gzopen("$filename.prc.gz", $zmode) or
          logmsg("F", "Couldn't open PRC gzip file")    if  $zFlag && $ZFlag;

      open SLB, "$mode$filename.slb" or 
	  logmsg("F", "Couldn't open '$filename.slb'")  if !$zFlag && $YFlag;
      $ZSLB=Compress::Zlib::gzopen("$filename.slb.gz", $zmode) or
          logmsg("F", "Couldn't open SLB gzip file")    if  $zFlag && $YFlag;
    }

    open TCP, "$mode$filename.tcp" or 
	  logmsg("F", "Couldn't open '$filename.tcp'")  if !$zFlag && $TFlag;
    $ZTCP=Compress::Zlib::gzopen("$filename.tcp.gz", $zmode) or
          logmsg("F", "Couldn't open TCP gzip file")    if  $zFlag && $TFlag;

    if ($autoFlush)
    {
      print "Setting non-compressed files to 'autoflush'\n"    if $debug & 1;
      if (defined(fileno($LOG)))  { select $LOG; $|=1; }
      if (defined(fileno(BLK)))   { select BLK;  $|=1; }
      if (defined(fileno(CLT)))   { select CLT;  $|=1; }
      if (defined(fileno(CPU)))   { select CPU;  $|=1; }
      if (defined(fileno(DSK)))   { select DSK;  $|=1; }
      if (defined(fileno(DSKX)))  { select DSKX; $|=1; }
      if (defined(fileno(ELN)))   { select ELN;  $|=1; }
      if (defined(fileno(ENV)))   { select ENV;  $|=1; }
      if (defined(fileno(IB)))    { select IB;   $|=1; }
      if (defined(fileno(OST)))   { select OST;  $|=1; }
      if (defined(fileno(NET)))   { select NET;  $|=1; }
      if (defined(fileno(NFS)))   { select NFS;  $|=1; }
      if (defined(fileno(PRC)))  { select PRC;  $|=1; }
      if (defined(fileno(SLB)))   { select SLB;  $|=1; }
      if (defined(fileno(TCP)))   { select TCP;  $|=1; }
    }
  }

  #    P u r g e    O l d    L o g s

  # ... but only if an interval specified
  # explicitly purge anything in the logging directory as long it looks like a collectl log
  # starting with the host name.  be sure we don't purge .log files because they're small and
  # good to have around.
  if ($purgeDays)
  {
    my ($day, $mon, $year)=(localtime(time-86400*$purgeDays))[3..5];
    my $purgeDate=sprintf("%4d%02d%02d", $year+1900, $mon+1, $day);
    $dirname=dirname($filename);
    if (opendir DIR, "$dirname")
    {
      while (my $filename=readdir(DIR))
      {
        next    if $filename=~/^\./;
        next    if $filename=~/log$/;
        next    if $filename!~/-(\d{8})(-\d{6})*\./ || $1 ge $purgeDate;

        unlink "$dirname/$filename";
      }
    }
    else
    {
      logmsg('E', "Couldn't open '$dirname' for purging");
    }
  }
  return 1;
}

# Build a common header for ALL files...
sub buildCommonHeader
{
  my $rawType=     shift;
  my $timeZoneInfo=shift;

  # if grouping we need to remove subsystems for groups not in
  # the associated files
  my $tempSubsys=$subsys;
  if ($groupFlag)
  {
    $tempSubsys=~s/Z+//g      if $rawType==0;
    $tempSubsys=~s/[^Z]+//g   if $rawType==1;
  }

  # We want to store all the interval(s) being used and not just what
  # the user specified with -i.  So include i2 if process/slabs and
  # i3 more for a placeholder
  $tempInterval=$interval;
  $tempInterval.=":$interval2"    if $subsys=~/[yz]/i;
  $tempInterval.=($subsys!~/[yz]/i) ? "::$interval3" : ":$interval3"
      if $subsys=~/E/;

  # For now, these are the only flags I can think of but clearly they
  # can grow over time...
  my $flags='';
  $flags.='i'    if $processIOFlag;
  $flags.='s'    if $slubinfoFlag;

  my $commonHeader='';
  if ($rawType!=-1 && $playback ne '')
  {
    $commonHeader.='#'x35;
    $commonHeader.=' RECORDED ';
    $commonHeader.='#'x35;
    $commonHeader.="\n# $recHdr1";
    $commonHeader.="\n# $recHdr2"    if $recHdr2 ne '';
    $commonHeader.="\n";
  }
  $commonHeader.='#'x80;
  $commonHeader.="\n# Collectl:   V$Version  HiRes: $hiResFlag  Options: $cmdSwitches\n";
  $commonHeader.="# Host:       $Host  DaemonOpts: $DaemonOptions\n";
  $commonHeader.=$timeZoneInfo  if defined($timeZoneInfo);
  $commonHeader.="# SubSys:     $tempSubsys SubOpts: $subOpts Options: $options  Interval: $tempInterval NumCPUs: $NumCpus $Hyper Flags: $flags\n";
  $commonHeader.="# HZ:         $HZ  Arch: $SrcArch PageSize: $PageSize\n";
  $commonHeader.="# Cpu:        $CpuVendor Speed(MHz): $CpuMHz Cores: $CpuCores  Siblings: $CpuSiblings\n";
  $commonHeader.="# Kernel:     $Kernel  Memory: $Memory  Swap: $Swap\n";
  $commonHeader.="# OF-Max:     $OFMax  SB-Max: $SBMax  DQ-Max: $DQMax\n"    if $iFlag;
  $commonHeader.="# NumDisks:   $NumDisks DiskNames: $DiskNames\n";
  $commonHeader.="# NumNets:    $NumNets NetNames: $NetNames\n";
  $commonHeader.="# NumSlabs:   $NumSlabs Version: $SlabVersion\n"    if $yFlag || $YFlag;
  $commonHeader.="# IConnect:   NumXRails: $NumXRails XType: $XType  XVersion: $XVersion\n"    if $NumXRails;
  $commonHeader.="# IConnect:   NumHCAs: $NumHCAs PortStates: $HCAPortStates IBVersion: $IBVersion\n"                if $NumHCAs;
  $commonHeader.="# SCSI:       $ScsiInfo\n"    if $ScsiInfo ne '';
  $commonHeader.="# Environ:    Fans: $NumFans  Power: $NumPwrs  Temp: $NumTemps\n"
      if $NumFans || $NumPwrs || $NumTemps;
  if ($subsys=~/l/i)
  {
    # Lustre Version and services (if any) info
    $commonHeader.="# Lustre:   ";
    $commonHeader.="  CfsVersion: $cfsVersion"       if $cfsVersion ne '';
    $commonHeader.="  SfsVersion: $sfsVersion"       if $sfsVersion ne '';
    $commonHeader.="  Services: $lustreSvcs";
    $commonHeader.="\n";

    $commonHeader.="# LustreServer:   NumMds: $NumMds MdsNames: $MdsNames  NumOst: $NumOst OstNames: $OstNames\n"
	if $NumOst || $NumMds;
    $commonHeader.="# LustreClient:   CltInfo:  $lustreCltInfo\n"
	if $CltFlag && $lustreCltInfo ne '';    # in case all filesystems umounted

    # more stuff for Disk Stats
    $commonHeader.="# LustreDisks:    Num: $NumLusDisks  Names: $LusDiskNames\n"
	if ($subOpts=~/D/);
  }
  $commonHeader.='#'x80;
  $commonHeader.="\n";

  return($commonHeader);
}

sub writeInterFileMarker
{
  # for now, only need one for process data
  my $marker="# >>> NEW LOG <<<\n";
  if ($subsys=~/Z/ && !$rawtooFlag)
  {
    $ZPRC->gzwrite($marker) or 
        writeError('prc', $ZPRC)    if  $zFlag;
    print PRC $marker               if !$zFlag;
  }
}

# see if there is a file that matches this filename root (should't have
# an extension).
sub plotFileExists
{
  my $filename=shift;
  my (@files, $file);

  @files=glob("$filename*");
  foreach $file (@files)
  {
      return(1)  if $file!~/raw/;
  }
    return(0);
}

# In retrospect, there are a number of special cases in here just for playback
# and things might be clearer to do away with this function and move code where
# it applies.
sub setOutputFormat
{
  # By default, we want to be in brief mode, but there are several cases in 
  # which we need to change the format to verbose, including --verbose 
  # writing to a file or in daemon mode, all of which are handled above.  
  $tempVerbose=0;
  $tempVerbose=1       if ($verboseFlag) ||
                        $subsys!~/^[$BriefSubsys]+$/ || $subOpts=~/[BDM]/ || $plotFlag || $daemonFlag;

  # If doing a single subsystem to the terminal in verbose mode, use -oh
  # we need the check for -oh because this gets called twice
  $options.='h'    if $filename eq ''  && $tempVerbose && $options!~/h/ && 
                      ($userOptions eq '' || $userOptions!~/h/) && 
		      length($subsys)==1;

  # just to keep it simple, when doing slabs or processes in verbose mode we DO want to print
  # headers for each interval and rather than complicate the logic above, do it separately.
  $options=~s/h//  if $verboseFlag && $subsys=~/[YZ]/;

  # As usual, lustre complicate things since we can get multiple lines of
  # output.  Therefore we need to see how many lustre options there actually
  # are and remove -oh if more than 1.
  my $numOpts=0;
  for (my $i=0; $subsys=~/l/i && $i<7; $i++)
  {
    my $char=substr('comBDMR', $i, 1);
    $numOpts++    if $subOpts=~/$char/;
  }
  $options=~s/h//    if $numOpts>1;

   # time doesn't print in verbose display (unless of course -oh set too)
  if ($tempVerbose && (!defined($options) || $options!~/h/))
  {
    $miniDateFlag=$miniTimeFlag=0;
    $miniDateTime=$miniFiller='';
  }

  # These 2 are always complementary
  $verboseFlag=$tempVerbose;
  $briefFlag=($tempVerbose) ? 0 : 1;
}

# Control C Processing
# This will wake us if we're sleeping or let us finish a collection cycle
# if we're not.
sub sigInt
{
  print "Ouch!\n"    if !$daemonFlag;
  $doneFlag=1;
}

sub sigTerm
{
  logmsg("W", "Shutting down in response to signal TERM on $myHost...");
  $doneFlag=1;
}

sub sigAlrm
{
  # This will set next alarm to the next interval that's a multiple of
  # our base time.  Note the extra 1000usecs which we need as fudge
  # Also note that arg[0] always defined with "ALRM" when ualarm below
  # fires so we need to use arg[1] as the 'first time' switch for 
  # logmsg() below.
  my ($intSeconds, $intUsecs)=Time::HiRes::gettimeofday();
  my $nowUSecs=$intSeconds*1000000+$intUsecs;
  my $secs=int(($nowUSecs-$BaseTime+$uAlignInt)/$uAlignInt)*$uAlignInt;
  my $waitTime=$BaseTime+$secs-$nowUSecs;
  Time::HiRes::ualarm($waitTime+1000);

  # message only on the very first call AND when --align since we always
  # align on an interval boundary anyway and don't want cluttered messages
  logmsg("I", "Waiting $waitTime usecs for time alignment")
      if defined($_[1]) && $alignFlag;

  # The following is all debug
  #($intSeconds, $intUsecs)=Time::HiRes::gettimeofday();
  #$nowUSecs2=$intSeconds*1000000+$intUsecs;
  #$diff=($nowUSecs2-$nowUSecs)/1000000;
  #printf "Start: %f  Current: %f  Wait: %f  Time: %f\n", $BaseTime/1000000, $nowUSecs/1000000, $waitTime/1000000, $diff;
}

# flush buffer(s) on sigUsr1
sub sigUsr1
{
  # There should be a small enough number of these to make it worth logging
  logmsg("I", "Flushing buffers in response to signal USR1")    if !$autoFlush;
  logmsg("W", "No need to signal 'USR1' since autoflushing")    if  $autoFlush;
  flushBuffers()    if !$autoFlush;
}

sub sigPipe
{
  logmsg("W", "Shutting down due to a broken pipe");
  $doneFlag=1;
}


sub flushBuffers
{
  # Remember, when $rawFlag set we flush everything including process/slab data.  But if
  # just $rawtooFlag set we those 2 other files aren't open and so we don't flush them.
  $flushTime=time+$flush     if $flushTime;

  if ($zFlag)
  {
    if ($rawFlag)
    {
      # if in raw mode, may be up to 2 buffers to flush
      $ZRAW-> gzflush(2)<0 and flushError('raw', $ZRAW)     if $recFlag0;
      $ZRAWP->gzflush(2)<0 and flushError('raw', $ZRAWP)    if $recFlag1;
      return    if !$plotFlag;
    }

    $ZLOG-> gzflush(2)<0 and flushError('log', $ZLOG)     if $subsys=~/[a-z]/;
    $ZBLK-> gzflush(2)<0 and flushError('blk', $ZBLK)     if ($LFlag || $LLFlag) && $subOpts=~/D/;
    $ZCPU-> gzflush(2)<0 and flushError('cpu', $ZCPU)     if $CFlag;
    $ZCLT-> gzflush(2)<0 and flushError('clt', $ZCLT)     if ($LFlag || $LLFlag) && $CltFlag;
    $ZDSK-> gzflush(2)<0 and flushError('dsk', $ZDSK)     if $DFlag && $options!~/x/;    # exception only file?
    $ZDSKX->gzflush(2)<0 and flushError('dskx',$ZDSKX)    if $DFlag && $options=~/x/i;
    $ZELN-> gzflush(2)<0 and flushError('eln', $ZELN)     if $XFlag && $NumXRails;
    $ZIB->  gzflush(2)<0 and flushError('ib',  $ZIB)      if $XFlag && $NumHCAs;
    $ZENV-> gzflush(2)<0 and flushError('env', $ZENV)     if $EFlag;
    $ZNFS-> gzflush(2)<0 and flushError('nfs', $ZNFS)     if $FFlag;
    $ZNET-> gzflush(2)<0 and flushError('net', $ZNET)     if $NFlag;
    $ZOST-> gzflush(2)<0 and flushError('ost', $ZOST)     if ($LFlag || $LLFlag) && $OstFlag;
    $ZTCP-> gzflush(2)<0 and flushError('tcp', $ZTCP)     if $TFlag;
    $ZSLB-> gzflush(2)<0 and flushError('slb', $ZSLB)     if $YFlag && !$rawtooFlag;
    $ZPRC-> gzflush(2)<0 and flushError('prc', $ZPRC)     if $ZFlag && !$rawtooFlag;
  }
  else
  {
    select $LOG;  $|=1; print $LOG ""; $|=0;  select STDOUT;
    return    if !$plotFlag;

    if ($CFlag)   { select CPU;  $|=1; print CPU ""; $|=0; }
    if ($DFlag)   { select DSK;  $|=1; print DSK ""; $|=0; }
    if ($EFlag)   { select ENV;  $|=1; print ENV ""; $|=0; }
    if ($FFlag)   { select NFS;  $|=1; print NFS ""; $|=0; }
    if ($NFlag)   { select NET;  $|=1; print NET ""; $|=0; }
    if ($TFlag)   { select TCP;  $|=1; print TCP ""; $|=0; }
    if ($XFlag && $NumXRails)                 { select ELN;  $|=1; print ELN ""; $|=0; }
    if ($XFlag && $NumHCAs)                   { select IB;   $|=1; print IB  ""; $|=0; }
    if ($YFlag && !$rawtooFlag)               { select SLB;  $|=1; print SLB ""; $|=0; }
    if ($ZFlag && !$rawtooFlag)               { select PRC;  $|=1; print PRC ""; $|=0; }
    if (($LFlag || $LLFlag) && $CltFlag)      { select CLT;  $|=1; print CLT ""; $|=0; }
    if (($LFlag || $LLFlag) && $OstFlag)      { select OST;  $|=1; print OST ""; $|=0; }
    if (($LFlag || $LLFlag) && $subOpts=~/D/) { select BLK;  $|=1; print BLK ""; $|=0; }

    if ($options=~/x/i)
    {
      if ($DFlag) { select DSKX;  $|=1; print DSKX ""; $|=0; }
    }
    select STDOUT;
  }
}

sub writeError
{
  my $file=shift;
  my $desc=shift;

  # just print the error and reopen ALL files (since it should be rare)
  # we also don't need to set '$recMode' in newLog() since not recursive.
  $zlibErrors++;
  logmsg("E", "Write error - File: $file Reason: $desc->gzerror()");
  logmsg("F", "Max Zlib error count exceeded")    if $zlibErrors>$MaxZlibErrors;
  $headersPrinted=0;
  newLog($filename, "", "", "", "", "");
}

sub flushError
{
  my $file=shift;
  my $desc=shift;

  # just print the error and reopen ALL files (since it should be rare)
  # we also don't need to set '$recMode' in newLog() since not recursive.
  $zlibErrors++;
  logmsg("E", "Flush error - File: $file Reason: $desc->gzerror()");
  logmsg("F", "Max Zlib error count exceeded")    if $zlibErrors>$MaxZlibErrors;
  $headersPrinted=0;
  newLog($filename, "", "", "", "", "");
}

# Note - ALL errors (both E and F) will be written to syslog.  If you want
# others to go there (such as startup/shutdown messages) you need to call
# logsys() directly.
sub logmsg
{
  my ($severity, $text)=@_;
  my ($ss, $mm, $hh, $day, $mon, $year, $msg, $time, $logname, $yymm, $date);

  # may need time if in debug and this routine gets called infrequently enough
  # that the extra processing is no big deal
  ($ss, $mm, $hh, $day, $mon, $year)=localtime(time);
  $time=sprintf("%02d:%02d:%02d", $hh, $mm, $ss);

  # always report non-informational messages and if not logging, we're done
  # BUT - if running as a daemon we CAN'T print because no terminal to talk to
  # We ONLY write to the log when writing to a file and -m
  $text="$time $text"      if $debug & 1;
  print STDERR "$text\n"   if !$daemonFlag && ($msgFlag || ($severity eq 'W' && !$quietFlag) || $severity=~/[EF]/ || $debug & 1);
  exit                     if !$msgFlag && $severity eq "F";
  return                   unless $msgFlag && $filename ne '';

  $yymm=sprintf("%d%02d", 1900+$year, $mon+1);
  $date=sprintf("%d%02d%02d", 1900+$year, $mon+1, $day);
  $msg=sprintf("%s-%s", $severity, $text);

  # the log file live in same directory as logs
  $logname=(-d $filename) ? $filename : dirname($filename);
  $logname.="/$myHost-collectl-$yymm.log";
  open  MSG, ">>$logname" or die "Couldn't open log file '$logname'";
  print MSG "$date $time $msg\n";
  close MSG;

  logsys($msg)    if $severity=~/EF/;
  exit            if $severity=~/F/;
}

sub logsys
{
  my $message=shift;

  if ($filename ne "")
  {
    #$x=Sys::Syslog::openlog($Program, "", "user");
    #$x=Sys::Syslog::syslog("info", $message);
    #Sys::Syslog::closelog();
  }
}

sub setFlags
{
  my $subsys=shift;

  # NOTE - are flags are faster than string compares?
  # unfortunate I got stuck using zFlag for ZIP and ZFlag for processes
  $cFlag=($subsys=~/c/) ? 1 : 0;  $CFlag=($subsys=~/C/) ? 1 : 0;
  $dFlag=($subsys=~/d/) ? 1 : 0;  $DFlag=($subsys=~/D/) ? 1 : 0;
                                  $EFlag=($subsys=~/E/) ? 1 : 0;
  $fFlag=($subsys=~/f/) ? 1 : 0;  $FFlag=($subsys=~/F/) ? 1 : 0;
  $iFlag=($subsys=~/i/) ? 1 : 0;
  $mFlag=($subsys=~/m/) ? 1 : 0;
  $nFlag=($subsys=~/n/) ? 1 : 0;  $NFlag=($subsys=~/N/) ? 1 : 0;
  $sFlag=($subsys=~/s/) ? 1 : 0;
  $tFlag=($subsys=~/t/) ? 1 : 0;  $TFlag=($subsys=~/T/) ? 1 : 0;
  $xFlag=($subsys=~/x/) ? 1 : 0;  $XFlag=($subsys=~/X/) ? 1 : 0;
  $yFlag=($subsys=~/y/) ? 1 : 0;  $YFlag=($subsys=~/Y/) ? 1 : 0;
                                  $ZFlag=($subsys=~/Z/) ? 1 : 0;

  # Special
  $LLFlag=0;
  $lFlag=($subsys=~/l/) ? 1 : 0;  $LFlag=($subsys=~/L/) ? 1 : 0;  
  if ($subsys=~/LL/)
  {
    $LFlag=0;
    $LLFlag=1;
  }

  # NOTE - the definition of 'core' as slightly changed and maybe should be
  # changed to be 'summary' to better reflect what we're trying to do.  
  $coreFlag=($subsys=~/[a-z]/) ? 1 : 0;

  # by default, all data gets logged in a single file.  if the group flag is set,
  # we defined flags that control recording into groups based on process/other
  # If we ever add more groups, we'll need to adjust the subsys in header accordingly
  $recFlag0=1;
  $recFlag1=0;
  if ($groupFlag)
  {
    $tempSys=$subsys;
    $tempSys=~s/Z//g;
    $recFlag0=0    if $tempSys eq '';
    $recFlag1=1    if $subsys=~/Z/;
  }
  print "RecFlags: $recFlag0 $recFlag1\n"    if $debug & 1;
}

sub getSeconds
{
  my $datetime=shift;
  my ($year, $mon, $day, $hh, $mm, $ss, $seconds);

  # missing 'seconds' field?
  $datetime.=":00"    if length($datetime)<15;

  $year=substr($datetime, 0,  4);
  $mon= substr($datetime, 4,  2);
  $day= substr($datetime, 6,  2);
  $hh=  substr($datetime, 9,  2);
  $mm=  substr($datetime, 12, 2);
  $ss=  substr($datetime, 15, 2);

  return(timelocal($ss, $mm, $hh, $day, $mon-1, $year-1900));
}

# print error and exit if bad datetime
sub checkTime
{
  my $switch=  shift;
  my $datetime=shift;
  my ($date, $time, $day, $mon, $year);

  # Make sure format correct. minimal being HH:MM. supply date and/or ":ss"
  $datetime.=":00"    if $datetime!~/\d{2}:\d{2}:\d{2}/;

  if ($datetime!~/-/)
  {
    ($day, $mon, $year)=(localtime(time))[3,4,5];
    $date=sprintf("%d%02d%02d", $year+1900, $mon+1, $day);
    $datetime="$date-$datetime";
  }

  error("$switch must be in [yyyymmdd-]hh:mm[:ss] format")
      if ($datetime=~/-/ && $datetime!~/\d{8}-\d{2}:\d{2}:\d{2}/);

  ($hh, $mm, $ss)=split(/:/, (split(/-/, $datetime))[1]);
  error("$switch specifies invalid time")     if ($hh>23 || $mm >59 || $ss>59);
}

sub closeLogs
{
  return    if !$logToFileFlag;
  print "Closing logs\n"    if $debug & 1;
  
  # closing raw files based on presence of zlib and NOT -oz
  if ($zlibFlag && $logToFileFlag && $rawFlag)
  {
    $ZRAW->  gzclose()    if $recFlag0;
    $ZRAWP-> gzclose()    if $recFlag1;
  }
  else
  {
    close $RAW     if defined($RAW)  && $recFlag0;
    close $RAWP    if defined($RAWP) && $recFlag1;
  }

  # doesn't hurt to close everything, even if not open
  if (!$zFlag)
  {
    close LOG;
    close BLK;
    close CPU;
    close CLT;
    close DSK;
    close DSKX;
    close ELN;
    close IB;
    close ENV;
    close NFS;
    close NET;
    close OST;
    close TCP;
    close SLB;
    close PRC;
  }
  else  # These must be opened in order to close them
  {
    $temp="$SubsysCore$SubsysExcore";
    $ZLOG-> gzclose()     if $plotFlag && $subsys=~/$temp/;
    $ZBLK-> gzclose()     if ($LFlag || $LLFlag) && $plotFlag && $subOpts=~/D/;
    $ZCLT-> gzclose()     if ($LFlag || $LLFlag) && $plotFlag && CltFlag;
    $ZCPU-> gzclose()     if $CFlag && $plotFlag;
    $ZDSK-> gzclose()     if $DFlag && $plotFlag && $options!~/x/;
    $ZDSKX->gzclose()     if $DFlag && $plotFlag && $options=~/x/i;
    $ZELN-> gzclose()     if $XFlag && $plotFlag && $NumXRails;
    $ZIB->  gzclose()     if $XFlag && $plotFlag && $NumHCAs;
    $ZENV-> gzclose()     if $EFlag && $plotFlag;
    $ZNFS-> gzclose()     if $FFlag && $plotFlag;
    $ZNET-> gzclose()     if $NFlag && $plotFlag;
    $ZOST-> gzclose()     if ($LFlag || $LLFlag) && $plotFlag && $OstFlag;
    $ZTCP-> gzclose()     if $TFlag && $plotFlag;
    $ZSLB-> gzclose()     if $YFlag && $plotFlag && !$rawtooFlag;
    $ZPRC-> gzclose()     if $ZFlag && $plotFlag && !$rawtooFlag;
  }
}

sub loadConfig
{
  my ($line, $num, $param, $value, $switches, $file, $openedFlag, $lib);

  # If no specified config file, look in /etc and then BinDir and then MyDir
  # Note - we can't use ':' as a separator because that screws up windows!
  if ($configFile eq '')
  {
    $configFile="/etc/$ConfigFile;$BinDir/$ConfigFile";
    $configFile.=";$MyDir/$ConfigFile"    if $BinDir ne '.' && $MyDir ne $BinDir;
  }
  print "Config File Path: $configFile\n"    if $debug & 1;

  $openedFlag=0;
  foreach $file (split(/;/, $configFile))
  {
    if (open CONFIG, "<$file")
    {
      print "Reading Config File: $file\n"    if $debug & 2;
      $openedFlag=1;
      last;
    }
  }
  logmsg("F", "Couldn't open '$configFile'")    if !$openedFlag;

  $num=0;
  foreach $line (<CONFIG>)
  {
    $num++;
    next    if $line=~/^\s*$|^\#/;    # skip blank lines and comments

    if ($line!~/=/)
    {
      logmsg("W", "CONFIG ERROR:  Line $num doesn't contain '='.  Ignoring...");
      next;
    }

    chomp $line;
    ($param, $value)=split(/\s*=\s*/, $line);
    print "Param: $param  Value: $value\n"    if $debug & 128;

    #    S u b s y s t e m s    A r e   S p e c i a l
 
    # Subsystems -- this is a little tricky because after user overrides
    # SubsysCore, SubsysExcore needs to contain all other core subsystems.
    if ($param=~/SubsysCore/)
    {
      # we put everything in 'Excore' and substract what's in 'Core'
      $SubsysExcore="$SubsysCore$SubsysExcore";
      error("config file entry for '$param' contains invalid subsystem(s) - $value")
	  if $value!~/^[$SubsysExcore]+$/;

      $SubsysCore=$value;
      $SubsysExcore=~s/[$SubsysCore]//g;
      next;
    }

    #    D a e m o n    P r o c e s s i n g

    elsif ($param=~/DaemonCommands/ && $daemonFlag)
    { 
      # Pull commmand string off line and add a 'special' end-of-line marker.
      # Note that we save off the whole thing for the header
      $DaemonOptions=$switches=(split(/=\s*/, $line))[1];
      $switches.=" -->>>EOL<<<";

      # We need to gather up switch and arg (if it has one) and then prepend onto
      # arg list so we still have an opportunity to override them at command line.
      # also note that end up getting added in reverse order but that should't
      # make a difference.
      $quote=0;
      $switch='';
      foreach $param (split(/\s+/, $switches))
      {
        if ($param=~/^-/)
        {
          # If new switch, time to write out old one (and arg)
	  if ($switch ne '')
          {
            unshift(@ARGV, $arg)    if $arg ne '';
            unshift(@ARGV, "$switch");
  	  }

	  last    if $param eq '-->>>EOL<<<';
          $switch=$param;
	  $arg='';
          next;
	}
        elsif ($quote)    # Processing quoted argument
        {
	  $quote=0    if $param=~/\"/;    # this is the last piece
	  $arg.=" $param";
	  next        if $quote!=0;
        }
	else  # unquoted argument
        {
          $arg=$param;
          $quote=1    if $param=~/\"/;
        }
      }
      #foreach my $arg (@ARGV) { print "$arg "; } print "\n"; exit;
    }   

    #    L i b r a r i e s    A r e    S p e c i a l    T o o

    elsif ($param=~/Libraries/)
    {
      $Libraries=$value;
      foreach $lib (split(/\s+/, $Libraries))
      {
        push @INC, $lib;
      }
    }

    #    S t a n d a r d    S e t

    else
    {
      $Grep=$value             if $param=~/^Grep/;
      $Egrep=$value            if $param=~/^Egrep/;
      $Ps=$value               if $param=~/^Ps/;
      $Rpm=$value              if $param=~/^Rpm/;
      $Ethtool=$value          if $param=~/^Ethtool/;
      $Lspci=$value            if $param=~/^Lspci/;
      $Lctl=$value             if $param=~/^Lctl/;

      # For Infiniband
      $PCounter=$value         if $param=~/^PCounter/;
      $PQueryList=$value       if $param=~/^PQuery/;
      $VStat=$value            if $param=~/^VStat/;

      $Interval=$value         if $param=~/^Interval$/;
      $Interval2=$value        if $param=~/^Interval2/;
      $Interval3=$value        if $param=~/^Interval3/;
      $LimSVC=$value           if $param=~/^LimSVC/;
      $LimIOS=$value           if $param=~/^LimIOS/;
      $LimLusKBS=$value        if $param=~/^LimLusKBS/;
      $LimLusReints=$value     if $param=~/^LimLusReints/;
      $LimBool=$value          if $param=~/^LimBool/;
      $Port=$value             if $param=~/^Port/;
      $Timeout=$value          if $param=~/^Timeout/;
      $MaxZlibErrors=$value    if $param=~/^ZMaxZlibErrors/;
      $Passwd=$value           if $param=~/^Passwd/;
      $LustreSvcLunMax=$value  if $param=~/^LustreSvcLunMax/;
      $LustreMaxBlkSize=$value  if $param=~/^LustreMaxBlkSize/;
      $LustreConfigInt=$value  if $param=~/^LustreConfigInt/;
      $InterConnectInt=$value  if $param=~/^InterConnectInt/;
      $HeaderRepeat=$value     if $param=~/^HeaderRepeat/;
      $DefNetSpeed=$value      if $param=~/^DefNetSpeed/;
    }
  }
  close CONFIG;

  foreach my $path (split(/:/, $PQueryList))
  {
    if (-e $path)
    {
      $PQuery=$path;
      print "PQuery=$PQuery\n"    if $debug & 128;
      last;
    }
  }
}

sub loadSlabs
{
  my $slabopts= shift;
  my ($line, $name, $slab, %slabsKnown);

  if ($slabinfoFlag)
  {
    if (!open PROC,"</proc/slabinfo")
    {
      logmsg("W", "Slab monitoring disabled because /proc/slabinfo doesn't exist");
      $yFlag=$YFlag=0;
      $subsys=~s/y//ig;
      return;
    }

    while ($line=<PROC>)
    {
      $slab=(split(/\s+/, $line))[0];
      $slabsKnown{$slab}=1;
    }

    # only if user specified -Y
    if ($slabopts ne '')
    {
      foreach $name (split(/,/, $slabopts))
      {
	if (-e $name)
        {
	  open SLABS,"<$name" or error("Couldn't open slablist file '$name'");
	  while ($slab=<SLABS>)
          {
	    # This allows one to cut/past /proc/slabinfo into the slab file and we just
	    # ignore data portions
	    $slab=(split(/\s+/, $slab))[0];
	    chomp $slab;
	    if (!defined($slabsKnown{$slab}))
	    {
	      logmsg("W", "Skipping unknown slab name: $slab in slab name file");
	      next;
	    }
	    $slabProc{$slab}=1;
          }
	  close SLABS;
        }
        else
        {
	  if (!defined($slabsKnown{$name}))
	  {
            logmsg("W", "Skipping unknown slab name: $name");
	    next;
          }
	  $slabProc{$name}=1;
        }
      }
    }  
    if ($debug & 1024)
    {
      print "*** SLABS ***\n";
      foreach $slab (sort keys %slabProc)
      { print "$slab\n"; }
    }
  }

  if ($slubinfoFlag)
  {
    ###########################################
    #    build list of all slabs NOT softlinks
    ###########################################

    opendir SYS, '/sys/slab' or logmsg('F', "Couldn't open '/sys/slab'");
    while (my $slab=readdir(SYS))
    {
      next    if $slab=~/^\./;

      # If a link, it's actually an alias
      $dirname="/sys/slab/$slab";
      if (-l $dirname)
      {
        # If filtering, only keep those aliases that match
        next    if $slabopts ne '' && !passSlabFilter($slabopts, $slab);

        # get the name of the slab this link points to
        my $linkname=readlink($dirname);
        my $rootslab=basename($linkname);

        # Note that since scalar returns the number of elements, it's always the index
        # we want to write the next entry into.  We also want to save a list of the link
        # names so we can easily skip over them later.
        my $alias=(defined($slabdata{$rootslab}->{aliases})) ? scalar(@{$slabdata{$rootslab}->{aliases}}) : 0;
        $slabdata{$rootslab}->{aliases}->[$alias]=$slab;
        $slabskip{$slab}=1;
      }
      else
      {
        $slabdata{$slab}->{lastobj}=$slabdata{$slab}->{lastslabs}=0;
      }
    }
   
    ##########################################
    #    secondary filter scan
    ##########################################

    if ($slabopts ne '')
    {
      # Note, at this point we only have aliases that pass the filter and so we need
      # to keep the entries OR we have entries with no aliases that might still pass 
      # filters only we couldn't check them yet so we need this second pass.
      foreach my $slab (keys %slabdata)
      {
        delete $slabdata{$slab}
	    if !defined($slabdata{$slab}->{aliases}) && !passSlabFilter($slabopts, $slab)
      }
    }

    ############################################################
    #    now find a better name to use, choosing length first
    ############################################################

    # what we want to do here is also build up a list of all the aliases to
    # make it easier to insert them into the header as well as display with
    # --showslabaliases.  Also note is --showrootslabs, we override '$first'
    # to that of the slab root name.
    foreach my $slab (sort keys %slabdata)
    {
      my ($first,$kmalloc,$list)=('','',' ');    # NOTE - $list set to leading space!
      foreach my $alias (@{$slabdata{$slab}->{aliases}})
      {
	$list.="$alias ";
	$kmalloc=$alias    if $alias=~/^kmalloc/;
	$first=$alias      if $alias!~/^kmalloc/ && length($alias)>length($first);
      }
      $first=$kmalloc    if $first eq '';
      $first=$slab       if $first eq '' || $showRootSlabsFlag;
      $slabdata{$slab}->{first}=$first;
      $slabfirst{$first}=$slab;

      # note that in some cases there is only a single alias in which case 'list' is ''
      $list=~s/ $first / /;
      $list=~s/^ | $//g;
      $slabdata{$slab}->{aliaslist}=$first       if $first ne $slab;
      $slabdata{$slab}->{aliaslist}.=" $list"    if $list ne '';
    } 
    ref($slabfirst);    # need to mention it to eliminate -w warning
  }
}

sub passSlabFilter
{
  my $filters=shift;
  my $slab=   shift;

  foreach my $name (split(/,/, $filters))
  {
    return(1)    if $slab=~/^$name/;
  }
  return(0);
}

# This needs some explaining...  When doing processes, we build a list of all the pids that
# match the -Z selection.  However, over time a selected command could exist and restart again
# under a different pid and we WANT to pick that up too.  So, everytime we check the processes
# and a non-pid selector has been specified we will have to recheck ALL pids to see in any new
# ones show up.  Naturally we can skip those in @skipPids and if the flag $pidsOnlyFlag is set
# we can also skip the pid checking.  Finally, since over time the list of pids can grow 
# unchecked we need to clean out the stale data after every polling cycle.
sub loadPids
{
  my $procs=shift;
  my ($process, $pid, $ppid, $user, $uid, $cmd, $line, $file, $temp);
  my ($type, $value, @ps, $selector, $pidOnly, $keepMe);

  # Step 0 - an enhancement!  If the process list string is actually a 
  # filename turn entries into one long string as if entered with -Z.
  # This makes it possible to have a constant -Z parameter yet change
  # the process list dynamically, before starting collectl.
  if (-e $procs)
  {
    $temp='';
    open TEMP, "<$procs" or logmsg("F", "Couldn't open -Z file");
    while ($line=<TEMP>)
    {
      chomp $line;
      next    if $line=~/^#|^\s*$/;  # ignore blank lines
      $line=~s/\s+//g;               # get rid of ALL whitespace in each line
      $temp.="$line,"                # smoosh it all together
    }
    $temp=~s/,$//;                   # get rid of trailing comma
    $procs=$temp;
  }

  # this is pretty brute force, but we're only doing it at startup
  # Step 1 - validate list for invalid types OR non-numeric pids
  #          assume including collectl
  $keepMe=1;
  $ThreadFlag=($procs=~/\+/) ? 1 : 0;    # handy flag to optimize non-thread cases
  foreach $task (split(/,/, $procs))
  {
    # for now, we don't do too much validation, but be sure to note
    # if our pid was requsted via 'p%'
    if ($task=~/^([cCpfPuU])\+*(.*)/)
    {
      $type=$1;
      $value=$2;

      # if we ever do allow this in playback we can't handle 'f'
      error("-Zf not allowed in playback mode")    if $type eq 'f' && $playback ne '';

      # pids must be numeric, but first replace '%' with our own pid
      if ($type=~/p/i)
      {
        if ($value eq '%')
        {
	  $keepMe=2;              # to signify '%p' used
	  $value=$$;
	  $pidThreads{$value}=0;  # never do threads for collectl
        }
        error("pid $value not numeric in -Z")    if $value!~/^\d+$/;
      }

      # when dealing with embedded string in command line, note that spaces
      # are converted to NULs, so do it to our match string so it only happens
      # once and also be sure to quote any meta charaters the user may have
      # in mind to use.  Since the contents of the 'f' option is in the
      # command line, we'd always include collectl as a match, so explicitly
      # remove it from the matching list by clearing the 'keepMe' flag.  However, if
      # 'collectl' itself has been specified by 'p%', we DO include it.
      if ($type eq 'f')
      {
        $task=~s/ /\000/g;
	$task=quotemeta($task);
	$keepMe=0    if $keepMe!=2;    # in case 'p%' preceeded this
      }

      push @TaskSelectors, $task;
      next;
    }
    else
    {
      error("invalid task selection in -Z: $task");
    }
  }

  # Step 2 - we need to get username/UIDs from here so we can reverse
  # map later on.  Note that in playback mode we may get them from elsewhere.
  loadUids('/etc/passwd');

  # Step 3 - find pids of all processes that match selection criteria
  #          be sure to truncate leading spaces since pids are fixed width
  # Note: $cmd incudes full directory path and args.  Furthermore, this is NOT
  # what gets stored in /proc/XXX/stat and to make sure we look at the same 
  # values dynamically as well as staticly, we better pull cmd from the stat
  # file itself.
  @ps=`ps axo pid,ppid,user,uid`;
  foreach $process (@ps)
  {
    next    if $process=~/^\s+PID/;
    $process=~s/^\s+//;

    ($pid, $ppid, $user, $uid)=split(/\s+/, $process, 4);

    # if we can't read proc, process must have existed
    next    if !open PROC, "</proc/$pid/stat";
    $line=<PROC>;
    close PROC;
    $cmd=(split(/ /, $line))[1];
    $cmd=~s/[()]//g;

    # if no criteria, select ALL
    if ($procs eq '')
    {
      $pidProc{$pid}=1;
      next;
    }

    # If our pid we decide to keep it based only on '$keepMe' flag
    if ($pid==$$)
    {
      if ($keepMe!=2)
      { $pidSkip{$pid}=1; }
      else
      { $pidProc{$pid}=1; }
      next;
    }

    # select based on criteria, but assume we're not getting a match
    $pidOnly=1;
    $keepPid=0;
    foreach $selector (@TaskSelectors)
    {
      $pidOnly=0    if $selector!~/^p/;
      if (($selector=~/^p\+*(.*)/ && $pid eq $1)  ||
	  ($selector=~/^P\+*(.*)/ && $ppid eq $1) ||
	  ($selector=~/^c\+*(.*)/ && $cmd=~/$1/)  ||
	  ($selector=~/^C\+*(.*)/ && $cmd=~/^$1/) ||
          ($selector=~/^f\+*(.*)/ && cmdHasString($pid,$1)) ||
	  ($selector=~/^u\+*(.*)/ && $uid eq $1)  ||
          ($selector=~/^U\+*(.*)/ && $user eq $1))
      {
	# We need to figure out if '+' appended to selector and set flag if so.
	# However, since it's extra overhead to maintain %pidThreads, we only set it
        # when there are threads to deal with.
	$pidThreads{$pid}=(substr($selector, 1, 1) eq '+') ? 1 : 0
	    if $ThreadFlag;

	$keepPid=1;
	last;
      }
    }

    if ($keepPid)
    { $pidProc{$pid}=1; }
    else
    { $pidSkip{$pid}=1; }
  }

  # STEP 4 - deal with threads
  # &pidThreads has been set to 1 for any pids we want to watch threads for. 
  # We clean this up when we clean pids in general.  If no pid threads, 
  # no %pidThreads.
  foreach $pid (keys %pidThreads)
  {
    findThreads($pid)    if $pidThreads{$pid};
  }

  # if only selecting on pids, those are all we ever want to look for
  # for force the $pidsOnlyFlag to be set.  It's those minor optimization
  # in life that count!
  $pidOnlyFlag=1    if $procs ne '' && $pidOnly;

  if ($debug & 256)
  {
    print "PIDS  Selected: ";
    foreach $pid (sort keys %pidProc)
    {
      print "$pid ";
    }
    print "\n";
    if ($ThreadFlag)
    {
      print "TPIDS Selected: ";
      foreach $pid (sort keys %tpidProc)
      {
        print "$pid ";
      }
    }
    print "\nPIDS  Skipped:  ";
    foreach $pid (sort keys %pidSkip)
    {
      print "$pid ";
    }
    print "\n";
    print "\$pidOnlyFlag set!!!\n"           if $pidOnlyFlag;
  }
}

sub loadUids
{
  my $passwd=shift;
  my (@passwd, $line, $user, $uid);

  @passwd=`$Cat $passwd`;
  foreach $line (@passwd)
  {
    next    if $line=~/^\+/;    # ignore '+' lines...

    ($user, $uid)=(split(/:/, $line))[0,2];
    $UidSelector{$uid}=$user;
  }
}

# here we have just found a new pid neither in the list to skip nor to process so
# we have to go back to our selector list and see if it meets the selection specs.
# if so, return the pid AND be sure to add to pidProc{} so we don't come here again.
# It seems that there are time we get called and /proc/$pid doesn't exist anymoe.
# My theory if these are short lived processes that are there whent he directory
# if first read but are gone by the time we want to open them.  For efficiency
# we do a test to see if the pid directory exists and then trap later opens in case it
# disappeared by then!
# NOTE - we could probably return 0/1 depending on whether or not pid found, but since
#        it's already in the $match variable, we return that for convenience
sub pidNew
{
  my $pid=shift;
  my ($selector, $type, $param, $match, $cmd, $ppid, $line, $uid);

  return(0)    if !-e "/proc/$pid/stat";

  $match=($procopts ne '') ? 0 : $pid;
  foreach $selector (@TaskSelectors)
  {
    $type=substr($selector, 0, 1);
    next              if  $type eq 'p';    # if a pid, can't be a new one

    $param=substr($selector, 1);
    if ($ThreadFlag)
    {
      $param=~s/(\+)//;
      $pidThreads{$pid}=($1 eq '+') ? 1 : 0;
    }

    # match on parents pid?  or command?
    if ($type=~/[PCc]/)
    {
      open PROC, "</proc/$pid/stat" or return(0);
      $temp=<PROC>;
      ($cmd, $ppid)=(split(/ /, $temp))[1,3];
      if (($type eq 'P' && $param==$ppid)      ||
          ($type eq 'C' && $cmd eq "($param)") ||
          ($type eq 'c' && $cmd=~/$param/))
      {
        $match=$pid;
	last;
      }
    }

    # match on full command path?
    elsif ($type=~/f/)
    {
      $match=$pid    if cmdHasString($pid, $param);
    }

    # match on username?
    elsif ($type=~/[uU]/)
    {
      # in case process went away we need to do a 'last'
      open TMP, "</proc/$pid/status" or last;
      while ($line=<TMP>)
      {
        if ($line=~/^Uid:\s+(\d+)/)
	{
	  $uid=$1;
	  $match=$pid    if defined($UidSelector{$uid});
	  last;
        }
      }
      logmsg("E", "Couldn't find UID for Pid: $pid")   if !$match;
    }
  }
  print "%%% Discovered new pid for monitoring: $pid\n"
      if $match && ($debug & 256);
  $pidProc{$match}=1     if $match!=0;
  findThreads($match)    if $match && $ThreadFlag && $pidThreads{$pid};
  return($match);
}

# see if the command that started a process contains a string
sub cmdHasString
{
  my $pid=   shift;
  my $string=shift;
  my $line;

  # Not an error because proc may have already exited
  return(0)    if (!open PROC, "</proc/$pid/cmdline");
  $cmdline=<PROC>;

  # since not all processes have command line associated with them be sure to
  # check before looking for a match and only return success after making it.
  return(!defined($cmdline) || $cmdline!~/$string/ ? 0 : 1)
}

# see if a pid has any active threads
sub findThreads
{
  my $pid=shift;

  # For now...
  if ($kernel2_6)
  {
    # In some cases the thread owning process may have gone away.  When this 
    # happens we can't open 'task', so act accordingly.
    if (!opendir DIR2, "/proc/$pid/task")
    {
	logmsg("W", "Looks like $pid exited so not looking for new threads");
	$pidThreads{$pid}=0;
	return;
    }
    while ($tpid=readdir(DIR2))
    {
      next    if $tpid=~/^\./;    # skip . and ..
      next    if $tpid==$pid;     # skip parent beause already covered

      # since this routine gets called both at the start when %tpidProc is empty and
      # every thread found is new AND during runtime when they may not be, check the
      # active thread hash and only include it if not already there
      if (!defined($tpidProc{$tpid}))
      {
        print "%%% Discovered new thread $tpid for pid: $pid\n"    if $debug & 256;
        $tpidProc{$tpid}=$pid;        # add to thread watch list
      }
    }
  }
}

sub cleanStalePids
{
  my ($pid, %pidTemp, %tpidTemp, $removeFlag, $x);

  $removeFlag=0;
  foreach $pid (keys %pidProc)
  {
    if ($pidSeen{$pid})
    {
      $pidTemp{$pid}=1;

      # If working with threads, we also need to purge the flag array that tells
      # us whether or not to look for thread pids
      $tpidTemp{$pid}=$pidThreads{$pid}    if $ThreadFlag;      
    }
    else
    {
      print "%%% Stale Pid: $pid\n"    if $debug & 256;
      $removeFlag=1;
    }
  }

  if ($removeFlag)
  {
    undef %pidProc;
    undef %pidThreads;
    %pidProc=%pidTemp;
    %pidThreads=%tpidTemp;
  }
  undef %pidTemp;
  undef %tpidTemp;

  if ($debug & 512)
  {
    foreach $x (sort keys %pidProc)
    { print "%%% pidProc{}: $x = $pidProc{$x}\n"; }
  }
  return    unless $ThreadFlag;
  
  # Do it again for threads...
  $removeFlag=0;
  foreach $pid (keys %tpidProc)
  {
    if ($tpidSeen{$pid})
    {
      $pidTemp{$pid}=$tpidProc{$pid};
    }
    else
    {
      print "%%% Stale TPid: $pid\n"    if $debug & 256;
      $removeFlag=1;
    }
  }

  if ($removeFlag)
  {
    undef %tpidProc;
    %tpidProc=%pidTemp;
  }
  undef %pidTemp;

  if ($debug & 512)
  {
    foreach $x (sort keys %tpidProc)
    { print "%%% tpidProc{}: $x = $tpidProc{$x}\n"; }
  }
}

sub showSlabAliases
{
  my $slabopts=shift;

  # by setting the slub flag and calling the 'load' routine, we'll get the header
  # built
  $slubinfoFlag= (-e '/sys/slab') ? 1 : 0;
  error("this kernel does not support 'slub-based' slabs")    if !$slubinfoFlag;
  loadSlabs($slabopts);

  foreach my $slab (sort keys %slabdata)
  {
    my $aliaslist=$slabdata{$slab}->{aliaslist};
    $aliaslist=$slab    if !defined($aliaslist);
    next    if $slab eq $aliaslist;
    printf "%-20s %s\n", $slab, $aliaslist    if $aliaslist=~/ /;
  }
  exit;
}

sub showVersion
{
  $temp='';
  $temp.="zlib,"     if $zlibFlag;
  $temp.="HiRes"     if $hiResFlag;
  $temp=~s/,$//;
  $version=sprintf("collectl V$Version %s\n\n", $temp ne '' ? "($temp)" : '');
  $version.="$Copyright\n";
  $version.="$License\n";
  printText($version);
  exit;
}

sub showDefaults
{
  printText("Default values by switch:\n");
  printText("              Interactive   Daemon\n");
  printText("  -c             -1         -1\n");
  printText("  -i             1:$Interval2:$Interval3   $Interval:$Interval2:$Interval3\n");
  printText("  -L             :$LustreConfigInt       :$LustreConfigInt\n");
  printText("  -s             cdn        $SubsysCore\n");
  printText("Defaults only settable in config file:\n");
  printText("  LimSVC        = $LimSVC\n");
  printText("  LimIOS        = $LimIOS\n");
  printText("  LimLusKBS     = $LimLusKBS\n");
  printText("  LimLusReints  = $LimLusReints\n");
  printText("  LimBool       = $LimBool\n");
  printText("  Port          = $Port\n");
  printText("  Timeout       = $Timeout\n");
  printText("  MaxZlibErrors = $MaxZlibErrors\n");
  printText("  Passwd        = $Passwd\n");
  printText("  Libraries     = $Libraries\n")    if defined($Libraries);
  exit;
}

sub error
{
  my $text=shift;
  if (defined($text))
  {
    printText("Error: $text\n");
    printText("type '$Program -h' for help\n");
    logmsg("F", "Error: $text")    if $daemonFlag;
    exit;
  }

my $help=<<EOF;
These are a subset of the basic switches and even the descripions are abbreviated.
To see all type 'collectl --helpext'.  To get started just type 'collectl'

usage: collectl [switches]
  -c, --count      count      collect this number of samples and exit
  -f, --filename   file       name of directory/file to write to
  -i, --interval   int        collection interval in seconds [default=10]
  -o, --options    options    list of miscellaneous options to control output format
                                d|D - include date in output
                                  T - include time in output
  -O, --subopts    subopts    list of sub-options that get applied to subsystems
                                NFS = [23C], Lustre = [BDMR], Processes = [P]
  -p, --playback   file       playback results from 'file'
  -P, --plot                  generate output in 'plot' format
  -s, --subsys     subsys     record/playback data from one or more subsystems
                                values = [cdfilmnstxyCDEFLLNTXYZ] defaults = [$SubsysCore]
  --verbose                   display output in verbose format (this mode can get automatically
                              selected in some cases where brief doesn't make sense)

Various types of help
  -h, --help                  print this text
  -v, --version               print version
  -V, --showdefs              print operational defaults
  -x, --helpext               extended help, some commands repeated in more detail

  --showoptions               show all the options
  --showsubopts               show all the suboptions
  --showsubsys                show all the subsystems
  --showheader                show file header that 'would be' generated
  --showslabaliases           for the new 'slub' slabs, show the aliases using non-root names
  --showrootslabs             same as --showslabaliases but use 'root' names

$Copyright
$License
EOF
printText($help);
exit;
}

sub extendHelp
{
my $extended=<<EOF2;
These switches are for more advanced usage

  --align          [core|proc]  align on time boundary (see man page for details)
  -A, --address    addr         write output to socket opened on this address:port
  -b, --begin      time         in playback mode, don't start at this date/time
                                time actually in '[date-]time' format
  -C, --config     file         use alternate collectl.conf file
      --custom     ph-file      this file-root (no .ph) will in included in the collectl source and
                                override the normal output pring routine
  -d, --debug      debug        see source for details or try -d 1 to get started
  -D, --daemon                  run as a daemon
  -e, --end        time         in playback mode, don't process after this date/time
  -F, --flush      seconds      number of seconds between output buffer flushes
  -G, --group                   write process and slab data to separate, rawp file
  -h, --help                    print basic help
      --headerrepeat num        repeat headers every 'num' lines of output
  -i, --interval   int[:pi:ei]] collection interval in seconds [default=10]
                                  pi is process interval [default=60]
                                  ei is environmental interval [defailt=300]
  -l, --limits     limits       override default exception limits name:val[-name:val]
                                see man page for details
  -L, --lustresvc  services     if specified, force monitoring/reporting on these lustre services
                                   c - client, m - mds, o - oss
  -m, --messages                write progress/errors in log file in -f directory or terminal
  -N, --nice                    give yourself a 'nicer' priority
EOF2
printText($extended);
showOptions(1);
showSubopts(1);
my $eof2a=<<EOF2a;
      --quiet                   do note echo warning messages on the terminal
  -r, --rolllogs   time,d,m     roll logs at 'time', retaining for 'd' days, every 'm' minutes
                                [default days=7, minutes=1440 (once a day)]
  -R, --runtime    duration     time to run in <num><units> format where unit is w,d,h,m,s
      --sep        separator    specify an alternate plot format separator
EOF2a
printText($eof2a);
showSubsys(1);
my $eof2b=<<EOF2b;
  -T, --timezone   hours        number of hours by which to offset times during playback
                                or blank to print times in the timezone where recorded
  --top             [num]       show top 'num' consumers of cpu each interval (DEF: 10)
  -w, --wide                    print wide field contents (don't use K/M/G)
  -Y, --slabopts   slabs        restricts which slabs are listed, where 'slab's is of the
                                form: 'slab[,slab...].  if 'slab' is a filename (you CAN mix them), 
                                it must contain a list of slabnames, one per line
  -Z, --procopts   procs        restricts which procs are listed, where 'procs' is of the
                                form: <type><match>[[,<type><match>],...].  Be sure to quote
                                if embedded spaces
                                  c - any substring in command name
                                  C - command name starts with this string
                                  f - full path of command (including args) contains string
                                  p - pid
                                  P - parent pid
                                  u - any processes owned by this user's UID
                                  U - any processes owned by this user
                                NOTE1:  if 'procs' is actually a filename, that file will be 
                                        read and all lines concatenated together, comma separted,
                                        as if typed in as an argument of -Z.  Lines beginning with
                                        # will be ignored as comments and blank lines skipped.
                                NOTE2:  if any type fields are immediatly followed by a plus sign,
                                        any threads associated with that process will also be reported.
                                        see man page for important restrictions

Synonyms
  --utc = -oU

These are Alternate Display Formats
  --procmem                   show memory utilization by process
  --procio                    show process level I/ counters
  --vmstat                    show output similar to vmstat

Logging options
  --rawtoo                    used with -P, write raw data to a log as well
  --sexpr {raw|rate}[,dir]    write data to an s-expression too (see man collectl-logging)

Various types of help
  -h, --help                  print this text
  -v, --version               print version
  -V, --showdefs              print operational defaults
  -x, --helpext               extended help, some commands repeated in more detail

  --showoptions               show all the display options
  --showsubopts               show all the subsystem options
  --showsubsys                show all the subsystems
  --showheader                show file header that 'would be' generated and exit
  --showplotheader            show plot headers that 'would be' generated and exit
  --showslabaliases           for the new 'slub' slabs, show the aliases using non-root names
  --showrootslabs             same as --showslabaliases but use 'root' names

EOF2b
printText($eof2b);
printText("$Copyright\n");
printText("$License\n");
exit;
}

sub showSubsys
{
  my $subsys=<<EOF3;
  -s, --subsys     subsys       only record/playback data from subsystem string
                                [default=$SubsysCore] where:
                                  c - cpu
                                  d - disk
                                  f - nfs
                                  i - inodes
                                  l - lustre
                                  m - memory
                                  n - network
                                  s - sockets
                                  t - tcp
                                  x - interconnect (currently supported: Infiniband and Quadrics)
                                  y - slabs
                                as an alternative format you can say '-s +[$SubsysExcore$SubsysDet]'
                                where '+xxx' adds major subsystems to '$SubsysCore'
                                  C -  individual CPUs
                                  D -  individual Disks
                                  E -  environmental (fans, temps, etc)
                                  F -  nsf detail data
                                  L -  lustre
                                  LL - ost level lustre details (clients & OSTs)
                                  N -  individual Networks
                                  T -  tcp details (lots of data!)
                                  X -  interconnect ports/rails (Infiniband/Quadrics)
                                  Y -  slabs
                                  Z -  processes (sorry, but P was already taken)
                                you can also specify '-s -[$SubsysCore]', with/without
                                the '+' option to remove default subsystems
EOF3
printText($subsys);
exit    if !defined($_[0]);
}

sub showOptions
{
  my $options=<<EOF4;
  -o, --options    options      list of miscellaneous options to control output format
                                NOTE - most CAN be used with -p

                                terminal output date/time format
                                  d - preface output with 'mm/dd hh:mm:ss'
                                  D - preface outout with 'ddmmyyyy hh:mm:ss'
                                  T - preface output with time only
                                  U - preface output with UTC time
                                  m - when reporting times, include milli-secs

                                terminal output headers
			              NOTE: change header repeat with --headerrepeat
                                  h - do NOT print multiple headers to terminal in verbose mode
                                  H - do NOT print any headers to terminal
                                  i - include file header in output
                                  t - start at top of page before printing interval headers
                                   
                                terminal output numerical formats
                                  g - include/substitute 'g' for decimal point for numbers > 1G
                                  G - include decimal point (when it will fit) for numbers > 1G

                                statistics
                                  A - show averages and totals after each playback file processed
				      NOTE - does NOT work in verbose mode

                                filtering
                                  s - for slab processing filter out slabs with 0 allocations
                                  S - for slab processing filter out slabs with no slab activity
                                  x - report exceptions only (see man page)
                                  X - record all values + exceptions in plot format (see manpage)
 
                                These modify the results before displaying
                                  F - use cumulative totals for maj/min faults in proc
                                      data instead of rates
                                  n - do NOT normalize rates to units/second
                                  P - for process playback on different nodes, use
                                      alternative passwd file (see man page)

                                plot file naming/creation
                                  a - if plotfile exists, append [default=skip -p file]
                                  c - always create new plot file
                                  u - create unique plot file names - include time

                                plot file data format
                                  1 - plot format with 1 decimal place of precision
                                  2 - plot format with 2 decimal places of precision
                                  z - don't compress output file(s)
EOF4
printText($options);
exit    if !defined($_[0]);
}

sub showSubopts
{
  my $subopts=<<EOF5;
  -O, --subopts    subopts      list of sub-options that get applied to subsystems
                                NFS
                                  2 - record nfs V2 statistics
                                  3 - record nfs V3 statistics [default]
                                  C - collect nfs client data (requires -s f/F)
                                Lustre
                                  B - only for OST's and clients, collect buffer/rpc stats
                                  D - collect lustre disk stats (MDS and OSS only)
                                  M - collect lustre client metadata
                                  R - collect lustre client readahead stats
                                Processes
                                  P - never look for new pids or threads to match processing
                                      criteria - (also improves performance)
EOF5

printText($subopts);
exit    if !defined($_[0]);
}
