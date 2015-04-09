# copyright, 2012 Hewlett-Packard Development Company, LP

# Debug
#   1 - print linux commands
#   2 - show most command output
#   4 - show instance, tap device and net index

# Restrictions
# - the design of export only allows you to call a single module and in most cases that's
#   'lexpr' BUT that interface allows lexpr to call another export module so you can do this:
#   	      --export lexpr,x=vmsum

# External globals
our %virtMacs;                                # from vnet.ph
our $lexOutputFlag;                           # tells us when lexpr output interval reached

# Internal globals
my $program='vmsum V1.0';
my %instances;
my $oneMB=1024*1024;
my ($debug, $helpFlag, $versionFlag, $zeroFlag);

my $Ssh= '/usr/bin/ssh';
my $Ping='/bin/ping';
my $PingTimeout=1;

# these control writing the vm text file
my $today;
my $lastDate=0;
my $printHeader;
my $textDir='';

my $lexprFlag=0;
my $noNetMsg='';    # if not null, problem with n/w stats (very rare)
my $hostname=`hostname`;
chomp $hostname;

sub vmsumInit
{
  # To keep things obvious, the first set of filters are passed to collectl
  # to just get what we want and the second set are used to verify its output.
  $colFilt='ckvm$,clibvirtd$,cqemu';
  $cmdFilt='kvm$|libvirtd$|qemu';

  if ($playback eq '')
  {
    error2("this is an --export module")                   if $import=~/vmsum/;
    error2("vmsum requires --import vnet")		   if $import!~/vnet/;
    print "warning: no disk stats unless you're root\n"    if !$rootFlag;

    # since this can be called via lexpr and we only want to do our processing during interval2, the easiest
    # thing to do is use the same values for both intervals.  Otherwise we need to figure out how to keep the
    # I1 stats correct when sending them to lexpr.  this is far easier, at least for now.  as long as I2 is
    # in the 5 second range that should be fine but if we want finer graularity we may need to rethink things.
    my ($int1, $int2)=split(/:/, $interval);
    $int2=$int1    if !defined($int2);
    $interval="$int2:$int2";

    # NOTE - for its first few seconds on life a kvm VM is named libvirtd and so
    # we need to check for both names or we might miss it.
    $procFilt=$colFilt;
  }
  else
  {
    error2("-s not allowed in playback mode")                if $userSubsys ne '';
    error2("this file does not contain process data!")       if $subsys!~/Z/;

    $noNetMsg="this file recorded without network stats"     if $noNetMsg eq '' && $subsys!~/n/i;

    my $options;
    my $daemonFlag=($header=~/Options: -D/) ? 1 : 0;
    $options=$1    if  $daemonFlag && $header=~/DaemonOpts:(.*)/m;    # we want leading space
    $options=$1    if !$daemonFlag && $header=~/Options:(.*)/m;

    my $temp=$1    if $options=~/--im\S+\s+(\S+)/;
  }

  # for now, if called via lexpr, we report data a different way!
  $lexprFlag=1    if $export=~/lexpr/;

  $startFlag=0;
  $uuidFlag=0;
  $debug=$helpFlag=$versionFlag=$zeroFlag=0;
  foreach my $option (@_)
  {
    # if called by lexpr,x=... $option passed as null string so can't split
    last    if $option eq '';

    my ($name, $value)=split(/=/, $option);
    error2("valid options are: [adhsStuv]")    if $name!~/^[adhsStuvz]$/;
    $addrFlag=1         if $name eq 'a';
    $debug=$value       if $name eq 'd';
    $helpFlag=1         if $name eq 'h';
    $startFlag|=1       if $name eq 's';
    $startFlag|=2       if $name eq 'S';
    $textDir=$value     if $name eq 't';
    $uuidFlag=1         if $name eq 'u';
    $versionFlag=1      if $name eq 'v';
    $zeroFlag=1         if $name eq 'z';
  }
  vmsumHelp()          if $helpFlag;
  vmsumVersion()       if $versionFlag;

  # make sure if not specified by user, we collectl process and n/w data
  $tempsys=$subsys;
  $tempsys.='Z'    if $subsys!~/Z/;
  $tempsys.='n'    if $subsys!~/n/i;
  $subsys=$userSubsys=$tempsys;

  error2("-f requires --rawtoo to get a raw file")              if $filename ne '' && !$rawtooFlag;
  error2("z only makes sense with sd")                          if $zeroFlag;
  error2("you can only specify s or S not both!")               if $startFlag==3;
  error2("--procopts s OR s/S flags but not both")              if $startFlag && $procOpts=~/s/i;
  error2("t= only with lexpr")                                  if $textDir ne '' && !$lexprFlag;
  error2("'$textDir' doesn't exist or is not a directory")      if $textDir ne '' && (!-e $textDir || !-d $textDir);

  # set up some things in collectl itself (requires DEEP knowledge)
  setOutputFormat();
  loadPids($procFilt);
  $interval2Secs=0;
  $DefNetSpeed=-1;	# disable checking for bogus network speeds on vlans

  if ($procOpts!~/s/i)
  {
    $procOpts.='s'    if $startFlag & 1;
    $procOpts.='S'    if $startFlag & 2;
  }
}

sub vmsum
{
  my $lineref=shift;    # lexpr the only one who passes this to us

  # when nothing to report these variables aren't set and do nothing sent back
  # if called from colmux.  Then, when colmux exists, the socket write won't 
  # happen and writeData() will never see a SIGPIPE and collectl won't exist.
  # so, since int1/int2 always the same during collection, this will force 
  # socket activity
  if ($playback eq '')
  {
    $interval2Print=1;
    $interval2Secs=$intSecs;
  }

  # only if time to print, noting colmux can call us with --showcolflag.
  # in realtime this is every interval because we've force i2=i
  return    if !$interval2Print && !$showColFlag;

  # if a process is discovered AFTER we start, this routine gets called called the first
  # time a process is seen and '$interval2Secs' will be 0!  In that one special case
  # we need to wait for the next interval before printing.
  return    if !$interval2Secs;

  $seconds=time;    # needed if printSeparator ever used

  #    F o r m a t t e d     T e x t    O u t p u t

  my $lines='';
  my $lexpr='';
  if (!$lexprFlag || $textDir ne '')
  {
    $datetime='';
    $tempFiller='';
    $separatorHeaderPrinted=1;    # suppress separator
    if ($options=~/[dDTm]/ || $textDir ne '')
    {
      my ($ss, $mm, $hh, $mday, $mon, $year)=localtime($lastSecs[0]);
      $today=sprintf('%d%02d%02d', $year+1900, $mon+1, $mday);
      $datetime=sprintf("%02d:%02d:%02d", $hh, $mm, $ss);
      $datetime=sprintf("%02d/%02d %s", $mon+1, $mday, $datetime)                   if $options=~/d/;
      $datetime=sprintf("%04d%02d%02d %s", $year+1900, $mon+1, $mday, $datetime)    if $options=~/D/;
      $datetime.=".$usecs"                                                          if ($options=~/m/);
      $datetime.=" ";
      $tempFiller=' ' x length($miniDateTime);
    }

    # see if we need a new VM log file
    if ($textDir ne '' && $today!=$lastDate)
    {
      my $filename="$textDir/$hostname-$today.vm";
      logmsg('I', "Opening $filename");
      open VMLOG, ">>$filename" or logmsg('E', "Couldn't open '$filename'");
      $lastDate=$today;
      $printHeader=1;
    }

    # we only print headers in the text file after opening it
    if (!$lexprFlag || $printHeader)
    {
      $lines.="\n"    if !$homeFlag;
      $temp1=($procOpts=~/f/) ? "(counters are cumulative)" : "(counters are $rate)";
      $temp2='';

      $lines.="# PROCESS SUMMARY $temp1$temp2$cpuDisabledMsg\n";
      $tempHdr='';
      $tempHdr.="#${tempFiller} PID  THRD S   VSZ   RSS CP  SysT  UsrT Pct  N   AccumTim ";    # using 'Time' breaks colmux
      $tempHdr.=sprintf("%s ", $procOpts=~/s/ ? 'StrtTime' : 'StartTime     ')    if $procOpts=~/s/i;
      $tempHdr.=sprintf("%-14s ", $addrFlag ? 'NetworkAddr' : '')                 if $addrFlag;
      $tempHdr.="DskI DskO NetI NetO Instance";
      $tempHdr.=" UUID"    if $uuidFlag;
      $lines.="$tempHdr\n";
      $printHeader=0;

      if ($showColFlag)
      {
        printText($lines);
        exit;
      }
    }
  }

  # Process in PID order
  my %procSort;
  foreach $pid (keys %procIndexes)
  {
    $procSort{sprintf("%06d", $pid)}=$pid;
  }

  my $eol='';
  my $procCount=0;
  foreach $key (sort keys %procSort)
  {
    # if screen already full
    last    if $numTop && ++$procCount>$numTop;

    # if we had partial data for this pid don't try to print!
    $i=$procIndexes{$procSort{$key}};
    next    if !defined($procSTimeTot[$i]);

    # even though we're looking for libvirtd initially so its pid doesn't get ignored
    # later, we DON'T want any stats on processes of that name.
    next    if $procName[$i] eq 'libvirtd';

    # If wide mode we include the command arguments AND chop trailing spaces
    ($cmd0, $cmd1)=(defined($procCmd[$i])) ? split(/\s+/,$procCmd[$i],2) : ($procName[$i],'');
    next    if $cmd0!~/$cmdFilt/;  # can get anything in playback and eveb libvirt in real time
    $qemuFlag=($cmd0=~/qemu/) ? 1 : 0;

    # the number cpus occurs here for both types of VMS (for at least now...)
    $cmd1=~/sockets=(\d+)/;
    my $numCPUs=$1;
    my $i2Secs=$interval2Secs;

    $cmd1=~/uuid (\S+)/;
    my $uuid=$1;
    #print "UUID: $uuid Flag: $uuidFlag\n";

    # it looks like a process can show up w/o complete set of args, so if this happens
    # we'll probably catch the full string in the next cycle (or two).  also the command
    # itself looks different for qemu and kvm
    $cmd1=~/instance-(\w+)/;
    my $instance=$1;
    #print "INST: $instance\n";
    next    if !defined($uuid) || !defined($instance);

    # only if no network problems, noting problems are rare, we need to find the index
    # to this VM's network stats
    my $netIndex=-1;
    if ($noNetMsg eq '')
    {
      # for now, it's either qemu or assume it's kvm
      if ($qemuFlag)
      {
        if ($cmd1=~/,mac=(.*?),/)
        {
          my $mac=$1;
          $mac=~s/^.{3}//;    # always ignore first octet since vnet does too AND they're different!
          $netIndex=$networks{$virtMacs{$mac}}    if $noNetMsg eq '';
          print "Inst: $instance  VIRT: $virtMacs{$mac}  MAC: $mac  NetIndex: $netIndex\n"    if $debug & 4;
        }        
        else
        { print "Inst: $instance  No Net!\n"  if $debug & 4; }
      }
      else
      {
        # so far haven't see any instances w/o ifname in them...
        $cmd1=~/,ifname=(.*?),/;
        my $tapdev=$1;
        $netIndex=$networks{$tapdev};
        print "Inst: $instance  Tap: $tapdev  NetIndex: $netIndex\n"    if $debug & 4;
      }
    }

    # Write to terminal OR vm text file
    if (!$lexprFlag || $textDir)
    {
      $line=sprintf("$datetime%5d%s %4d %1s %5s %5s %2d %s %s %s %2d %10s ",
                $procPid[$i],  $procThread[$i] ? '+' : ' ',
		$procTCount[$i], $procState[$i],
		defined($procVmSize[$i]) ? cvt($procVmSize[$i],4,1,1) : 0,
		defined($procVmRSS[$i])  ? cvt($procVmRSS[$i],4,1,1)  : 0,
		$procCPU[$i],
		cvtT1($procSTime[$i]), cvtT1($procUTime[$i]),
                cvtP(($procSTime[$i]+$procUTime[$i])/$numCPUs),
		$numCPUs,
                cvtT2($procSTimeTot[$i]+$procUTimeTot[$i]));
      $line.=sprintf("%s ", cvtT5($procSTTime[$i]))                                                                    if $startFlag || $procOpts=~/s/i;
      $line.=sprintf("%-14s ", (defined($instances{$instance}->{address})) ? $instances{$instance}->{address} : '')    if $addrFlag;

      if ($rootFlag || $lexprFlag)
      { $line.=sprintf("%4s %4s ", cvt($procRKB[$i]/$i2Secs,4,0,1), cvt($procWKB[$i]/$i2Secs,4,0,1)); }
      else
      { $line.=sprintf("%4s %4s ", '-1', '-1'); }

      # we'll virtually always have network stats but we want to differentiate between an uninitt network index,
      # which is a bug, and somehow not having recorded things with -sn.  There are also cases where there is no
      # network (seen during testing for qemu) and for those report -1
      if ($subsys=~/n/i)
      {
	# this is the normal case
	if (defined($netIndex) && $netIndex != -1)
        {
          $line.=sprintf("%4s %4s ",
		defined($netRxKB[$netIndex]) ? cvt($netRxKB[$netIndex]/$i2Secs) : '???',
		defined($netTxKB[$netIndex]) ? cvt($netTxKB[$netIndex]/$i2Secs) : '???');
        }

        # these nest 2 cases typically shouldn't happen but during testing I've seen
	# transient cases where $netIndex wasn't defined, perhaps a network was just coming up?
	# I could have combined with the -1 case but want to differentiate, at least for now.
        elsif (!defined($netIndex))
	{
	  $line.=sprintf("%4s %4s ", '!!!', '!!!');
	}
	else
	{
          $line.=sprintf("%4s %4s ", '-1', '-1');
	}
      }
      else
      {
        $line.=sprintf("%4s %4s ", 0, 0);
      }

      $line.=sprintf("%s", $instance);
      $line.=sprintf(" %s", $uuid)    if $uuidFlag;
      $line.=$eol    if $playback eq '' && $numTop;
      $line.="\n"    if $playback ne '' || !$numTop || $procCount<$numTop;
      $lines.=$line;
    }

    # we might end up writing to 2 places...
    if ($lexprFlag)
    {
      # remember, even with i=60,tot, lexpr calls us every time and we need to call sendData() so
      # so the totals are correctly calculated.  Further, when passing rates that's ok too because
      # lexpr totals them up and divides by the number of samples preserving the correct average
      $lexpr.=sendData("vm.$instance.dskrkb",  $procRKB[$i]/$i2Secs);
      $lexpr.=sendData("vm.$instance.dskwkb",  $procWKB[$i]/$i2Secs);

      if ($noNetMsg eq '')
      {
        $lexpr.=sendData("vm.$instance.netrx", $netRxKB[$netIndex]/$i2Secs);
        $lexpr.=sendData("vm.$instance.nettx", $netTxKB[$netIndex]/$i2Secs);
      }
    }
  }

  #    A c t u a l    O u t p u t    H a p p e n s     H e r e

  if (!$lexprFlag)
  {
    # only time we go to terminal, which is probably most of the time
    printText($lines)    if $filename eq '';

    # clear to the end of the display in case doing --procopts z, since the process list
    # length changes dynamically
    print $clr    if $numTop && $playback eq '';
  }
  else
  {
    $$lineref.=$lexpr;
    print VMLOG $lines    if $textDir ne '';
  }
}

# The main point of this routine is for cases where we might be run from colmux, there's no way to tell which
# node error messages may have come from!
sub error2
{
  error("$hostname: $_[0]");
}

sub vmsumVersion
{
  print "$program\n";
  exit;
}

sub vmsumHelp
{
  my $help=<<VMSUMEOF;

usage: collectl --export kvmsum[,switches]
  a         include network address
  d=mask    debugging mask, see start of module for descriptions
  h         print this text
  s         include process start time, noting you can also use --procopt s
  t=dir     write process stats to text file in specified directory, ONLY with lexpr
  v         print version and exit
  z         suppress lines with 0 I/Os

VMSUMEOF

  print $help;
  exit;
}

1;
