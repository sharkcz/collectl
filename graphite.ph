# copyright, 2003-20012 Hewlett-Packard Development Company, LP

#  debug
#    1 - print Var, Units and Values
#    2 - only print sent 'changed' Var/Units/Vales
#    4 - not used
#    8 - do not open/use socket (typically used with other flags)
#   16 - print socket open/close info

my $graphiteTimeout=5;
my $graphiteCounter=0;
my $graphiteSocketFailMax=5;    # report socket open fails every 100 intervals
my $graphiteIntTimeLast=0;      # tracks start of new interval
my $graphiteOneTB=1024*1024*1024*1024;
my $graphitePost='';            # insert AFTER hostname in message to carbon (don't forget '.' if you want one)
my ($graphiteSubsys, $graphiteInterval);
my ($graphiteDebug, $graphiteCOFlag, $graphiteTTL, @graphiteTTL, $graphiteDataIndex, @graphiteDataLast);
my ($graphiteMyHost, $graphiteSocket, $graphiteSockHost, $graphiteSockPort, $graphiteSocketFailCount);
my ($graphiteMinFlag, $graphiteMaxFlag, $graphiteAvgFlag, $graphiteMmaFlags)=(0,0,0,0);

sub graphiteInit
{
  my $hostport=shift;
  help()    if $hostport eq 'h';

  error("host[:port] must be specified as first parameter")    if !defined($hostport);
  error('--showcolheader not supported by graphite')           if $showColFlag;

  # Just like vmstat
  error("-f requires either --rawtoo or -P")     if $filename ne '' && !$rawtooFlag && !$plotFlag;
  error("-P or --rawtoo require -f")             if $filename eq '' && ($rawtooFlag || $plotFlag);

  # If we ever run with a ':' in the inteval, we need to be sure we're
  # only looking at the main one.
  my $graphiteInterval1=(split(/:/, $interval))[0];

  # parameter defaults
  $hostport.=":2003"    if $hostport!~/:/;
  $graphiteDebug=$graphiteCOFlag=0;
  $graphiteInterval=$graphiteInterval1;
  $graphiteSubsys=$subsys;
  $graphiteTTL=5;

  foreach my $option (@_)
  {
    my ($name, $value)=split(/=/, $option);
    error("invalid graphite option '$name'")    if $name!~/^[dhips]?$|^co$|^ttl$|^min$|^max$|^avg$/;
    $graphiteCOFlag=1           if $name eq 'co';
    $graphiteDebug=$value       if $name eq 'd';
    $graphiteInterval=$value    if $name eq 'i';
    $graphitePost=$value        if $name eq 'p';
    $graphiteSubsys=$value      if $name eq 's';
    $graphiteTTL=$value         if $name eq 'ttl';
    $graphiteMinFlag=1          if $name eq 'min';
    $graphiteMaxFlag=1          if $name eq 'max';
    $graphiteAvgFlag=1          if $name eq 'avg';

    help()                      if $name eq 'h';
  }

  error("graphite does not support standard collectl socket I/O via -A")   if $graphiteSockFlag;
  ($graphiteSockHost, $graphiteSockPort)=split(/:/, $hostport);
  error("the port number must be specified")    if !defined($graphiteSockPort) || $graphiteSockPort eq '';

  error("graphite subsys options '$graphiteSubsys' not a proper subset of '$subsys'")
        if $subsys ne '' && $graphiteSubsys!~/^[$subsys]+$/;

  # convert to the number of samples we want to send
  $graphiteSendCount=int($graphiteInterval/$graphiteInterval1);
  error("graphite interval option not a multiple of '$graphiteInterval1' seconds")
	if $graphiteInterval1*$graphiteSendCount != $graphiteInterval;

  $graphiteMmaFlags=$graphiteMinFlag+$graphiteMaxFlag+$graphiteAvgFlag;
  error("only 1 of 'min', 'max' or 'avg' with 'graphite'")    if $graphiteMmaFlags>1;
  error("'min', 'max' and 'avg' require graphite 'i' that is > collectl's -i")
        if $graphiteMmaFlags && $graphiteSendCount==1;

  # Since graphite DOES write over a socket but does not use -A, make sure the default
  # behavior for -f logs matches that of -A
  $rawtooFlag=1    if $filename ne '' && !$plotFlag;

  $graphiteMyHost=`hostname`;
  chomp $graphiteMyHost;
  $graphiteMyHost=(split(/\./, $graphiteMyHost))[0];

  #    O p e n    S o c k e t

  $SIG{"PIPE"}=\&graphiteSigPipe;    # socket comm errors

  # set fail count such that if first open fails, we'll report an error
  $graphiteSocketFailCount=$graphiteSocketFailMax-1;
  openTcpSocket(1);
}

# NOTE - this routine is almost an identical copy from gexpr.
# Being lazy while making it easier to keep the 2 in sync, I left in the
# second parameter in the sendData() calls which are ignored in the
# modified version of sendData() itself, which prepends a hostname to the
# variable name and add a timestamp to the socket call.  In fact, I almost
# just hacked up gexpr to make it deal with both ganglia and graphite.
sub graphite
{
  # if socket not even open and the first try of this interval, try again
  # NOTE - we're making sure socket is open every interval whether we're
  # reporting data or not...
  openTcpSocket()    if !defined($graphiteSocket) && $graphiteIntTimeLast!=time;
  $graphiteIntTimeLast=time;
  return             if !defined($graphiteSocket) && !($graphiteDebug & 8);    # still not open?  get out!

  # if not time to print and we're not doing min/max/tot, there's nothing to do.
  $graphiteCounter++;
  return    if ($graphiteCounter!=$graphiteSendCount && $graphiteMmaFlags==0);

  # We ALWAYS process the same number of data elements for any collectl instance
  # so we can use a global index to point to the one we're currently using.
  $graphiteDataIndex=0;

  if ($graphiteSubsys=~/c/)
  {
    # CPU utilization is a % and we don't want to report fractions
    my $i=$NumCpus;

    sendData('cputotals.user', 'percent', $userP[$i]);
    sendData('cputotals.nice', 'percent', $niceP[$i]);
    sendData('cputotals.sys',  'percent', $sysP[$i]);
    sendData('cputotals.wait', 'percent', $waitP[$i]);
    sendData('cputotals.idle', 'percent', $idleP[$i]);
    sendData('cputotals.irq',  'percent', $irqP[$i]);
    sendData('cputotals.soft', 'percent', $softP[$i]);
    sendData('cputotals.steal','percent', $stealP[$i]);

    sendData('ctxint.ctx',  'switches/sec', $ctxt/$intSecs);
    sendData('ctxint.int',  'intrpts/sec',  $intrpt/$intSecs);
    sendData('ctxint.proc', 'pcreates/sec', $proc/$intSecs);
    sendData('ctxint.runq', 'runqSize',     $loadQue);

    sendData('cpuload.avg1',   'loadAvg1',  $loadAvg1);
    sendData('cpuload.avg5',   'loadAvg5',  $loadAvg5);
    sendData('cpuload.avg15',  'loadAvg15', $loadAvg15);
  }

  if ($graphiteSubsys=~/C/)
  {
    for (my $i=0; $i<$NumCpus; $i++)
    {
      sendData("cpuinfo.user.cpu$i",  'percent', $userP[$i]);
      sendData("cpuinfo.nice.cpu$i",  'percent', $niceP[$i]);
      sendData("cpuinfo.sys.cpu$i",   'percent', $sysP[$i]);
      sendData("cpuinfo.wait.cpu$i",  'percent', $waitP[$i]);
      sendData("cpuinfo.irq.cpu$i",   'percent', $irqP[$i]);
      sendData("cpuinfo.soft.cpu$i",  'percent', $softP[$i]);
      sendData("cpuinfo.steal.cpu$i", 'percent', $stealP[$i]);
      sendData("cpuinfo.idle.cpu$i",  'percent', $idleP[$i]);
      sendData("cpuinfo.intrpt.cpu$i",'percent', $intrptTot[$i]);
    }
  }

  if ($graphiteSubsys=~/d/)
  {
    sendData('disktotals.reads',    'reads/sec',    $dskReadTot/$intSecs);
    sendData('disktotals.readkbs',  'readkbs/sec',  $dskReadKBTot/$intSecs);
    sendData('disktotals.writes',   'writes/sec',   $dskWriteTot/$intSecs);
    sendData('disktotals.writekbs', 'writekbs/sec', $dskWriteKBTot/$intSecs);
  }

  if ($graphiteSubsys=~/D/)
  {
    for (my $i=0; $i<$NumDisks; $i++)
    {
      sendData("diskinfo.reads.$dskName[$i]",    'reads/sec',    $dskRead[$i]/$intSecs);
      sendData("diskinfo.readkbs.$dskName[$i]",  'readkbs/sec',  $dskReadKB[$i]/$intSecs);
      sendData("diskinfo.writes.$dskName[$i]",   'writes/sec',   $dskWrite[$i]/$intSecs);
      sendData("diskinfo.writekbs.$dskName[$i]", 'writekbs/sec', $dskWriteKB[$i]/$intSecs);
    }
  }

  if ($graphiteSubsys=~/f/)
  {
    if ($nfsSFlag)
    {
      sendData('nfsinfo.SRead',   'SvrReads/sec',  $nfsSReadsTot/$intSecs);
      sendData('nfsinfo.SWrite',  'SvrWrites/sec', $nfsSWritesTot/$intSecs);
      sendData('nfsinfo.Smeta',   'SvrMeta/sec',   $nfsSMetaTot/$intSecs);
      sendData('nfsinfo.Scommit', 'SvrCommt/sec' , $nfsSCommitTot/$intSecs);
    }
    if ($nfsCFlag)
    {
      sendData('nfsinfo.CRead',   'CltReads/sec',  $nfsCReadsTot/$intSecs);
      sendData('nfsinfo.CWrite',  'CltWrites/sec', $nfsCWritesTot/$intSecs);
      sendData('nfsinfo.Cmeta',   'CltMeta/sec',   $nfsCMetaTot/$intSecs);
      sendData('nfsinfo.Ccommit', 'CltCommt/sec' , $nfsCCommitTot/$intSecs);
    }
  }

  if ($graphiteSubsys=~/i/)
  {
    sendData('inodeinfo.dentnum',    'dentrynum',    $dentryNum);
    sendData('inodeinfo.dentunused', 'dentryunused', $dentryUnused);
    sendData('inodeinfo.fhandalloc', 'filesalloc',   $filesAlloc);
    sendData('inodeinfo.fhandmpct',  'filesmax',     $filesMax);
    sendData('inodeinfo.inodenum',   'inodeused',    $inodeUsed);
  }

  if ($graphiteSubsys=~/l/)
  {
    if ($CltFlag)
    {
      sendData('lusclt.reads',    'reads/sec',    $lustreCltReadTot/$intSecs);
      sendData('lusclt.readkbs',  'readkbs/sec',  $lustreCltReadKBTot/$intSecs);
      sendData('lusclt.writes',   'writes/sec',   $lustreCltWriteTot/$intSecs);
      sendData('lusclt.writekbs', 'writekbs/sec', $lustreCltWriteKBTot/$intSecs);
      sendData('lusclt.numfs',    'filesystems',  $NumLustreFS);
    }

    if ($MdsFlag)
    {
      my $getattrPlus=$lustreMdsGetattr+$lustreMdsGetattrLock+$lustreMdsGetxattr;
      my $setattrPlus=$lustreMdsReintSetattr+$lustreMdsSetxattr;
      my $varName=($cfsVersion lt '1.6.5') ? 'reint' : 'unlink';
      my $varVal= ($cfsVersion lt '1.6.5') ? $lustreMdsReint : $lustreMdsReintUnlink;

      sendData('lusmds.gattrP',    'gattrP/sec',   $getattrPlus/$intSecs);
      sendData('lusmds.sattrP',    'sattrP/sec',   $setattrPlus/$intSecs);
      sendData('lusmds.sync',      'sync/sec',     $lustreMdsSync/$intSecs);
      sendData("lusmds.$varName",  "$varName/sec", $varVal/$intSecs);
    }

    if ($OstFlag)
    {
      sendData('lusost.reads',    'reads/sec',    $lustreReadOpsTot/$intSecs);
      sendData('lusost.readkbs',  'readkbs/sec',  $lustreReadKBytesTot/$intSecs);
      sendData('lusost.writes',   'writes/sec',   $lustreWriteOpsTot/$intSecs);
      sendData('lusost.writekbs', 'writekbs/sec', $lustreWriteKBytesTot/$intSecs);
    }
  }

  if ($graphiteSubsys=~/L/)
  {
    if ($CltFlag)
    {
      # Either report details by filesystem OR OST
      if ($lustOpts!~/O/)
      {
        for (my $i=0; $i<$NumLustreFS; $i++)
        {
          sendData("lusost.reads.$lustreCltFS[$i]",    'reads/sec',    $lustreCltRead[$i]/$intSecs);
	  sendData("lusost.readkbs.$lustreCltFS[$i]",  'readkbs/sec',  $lustreCltReadKB[$i]/$intSecs);
          sendData("lusost.writes.$lustreCltFS[$i]",   'writes/sec',   $lustreCltWrite[$i]/$intSecs);
          sendData("lusost.writekbs.$lustreCltFS[$i]", 'writekbs/sec', $lustreCltWriteKB[$i]/$intSecs);
        }
      }
      else
      {
        for (my $i=0; $i<$NumLustreCltOsts; $i++)
        {
          sendData("lusost.reads.$lustreCltOsts[$i]",    'reads/sec',    $lustreCltLunRead[$i]/$intSecs);
          sendData("lusost.readkbs.$lustreCltOsts[$i]",  'readkbs/sec',  $lustreCltLunReadKB[$i]/$intSecs);
          sendData("lusost.writes.$lustreCltOsts[$i]",   'writes/sec',   $lustreCltLunWrite[$i]/$intSecs);
          sendData("lusost.writekbs.$lustreCltOsts[$i]", 'writekbs/sec', $lustreCltLunWriteKB[$i]/$intSecs);
        }
      }
    }

    if ($OstFlag)
    {
      for ($i=0; $i<$NumOst; $i++)
      {
        sendData("lusost.reads.$lustreOsts[$i]",    'reads/sec',    $lustreReadOps[$i]/$intSecs);
        sendData("lusost.readkbs.$lustreOsts[$i]",  'readkbs/sec',  $lustreReadKBytes[$i]/$intSecs);
        sendData("lusost.writes.$lustreOsts[$i]",   'writes/sec',   $lustreWriteOps[$i]/$intSecs);
        sendData("lusost.writekbs.$lustreOsts[$i]", 'writekbs/sec', $lustreWriteKBytes[$i]/$intSecs);
      }
    }
  }

  if ($graphiteSubsys=~/m/)
  {
    sendData('meminfo.tot',       'kb',         $memTot);
    sendData('meminfo.free',      'kb',         $memFree);
    sendData('meminfo.shared',    'kb',         $memShared);
    sendData('meminfo.buf',       'kb',         $memBuf);
    sendData('meminfo.cached',    'kb',         $memCached);
    sendData('meminfo.used',      'kb',         $memUsed);
    sendData('meminfo.slab',      'kb',         $memSlab);
    sendData('meminfo.map',       'kb',         $memMap);
    sendData('meminfo.hugetot',   'kb',         $memHugeTot);
    sendData('meminfo.hugefree',  'kb',         $memHugeFree);
    sendData('meminfo.hugersvd',  'kb',         $memHugeRsvd);

    sendData('swapinfo.total',    'kb',         $swapTotal);
    sendData('swapinfo.free',     'kb',         $swapFree);
    sendData('swapinfo.used',     'kb',         $swapUsed);
    sendData('swapinfo.in',       'swaps/sec',  $swapin/$intSecs);
    sendData('swapinfo.out',      'swaps/sec',  $swapout/$intSecs);

    sendData('pageinfo.fault',    'faults/sec', $pagefault/$intSecs);
    sendData('pageinfo.majfault', 'majflt/sec', $pagemajfault/$intSecs);
    sendData('pageinfo.in',       'pages/sec',  $pagein/$intSecs);
    sendData('pageinfo.out',      'pages/sec',  $pageout/$intSecs);
  }

  if ($graphiteSubsys=~/M/)
  {
    for (my $i=0; $i<$CpuNodes; $i++)
    {
      foreach my $field ('used', 'free', 'slab', 'map', 'anon', 'lock', 'act', 'inact')
      {
        sendData("numainfo.$field.$i", 'kb', $numaMem[$i]->{$field});
      }
    }
  }

  if ($graphiteSubsys=~/n/)
  {
    sendData('nettotals.kbin',   'kb/sec', $netRxKBTot/$intSecs);
    sendData('nettotals.pktin',  'kb/sec', $netRxPktTot/$intSecs);
    sendData('nettotals.kbout',  'kb/sec', $netTxKBTot/$intSecs);
    sendData('nettotals.pktout', 'kb/sec', $netTxPktTot/$intSecs);
  }

  if ($graphiteSubsys=~/N/)
  {
    for ($i=0; $i<$netIndex; $i++)
    {
      next    if $netName[$i]=~/lo|sit/;

      sendData("nettotals.kbin.$netName[$i]",   'kb/sec', $netRxKB[$i]/$intSecs);
      sendData("nettotals.pktin.$netName[$i]",  'kb/sec', $netRxPkt[$i]/$intSecs);
      sendData("nettotals.kbout.$netName[$i]",  'kb/sec', $netTxKB[$i]/$intSecs);
      sendData("nettotals.pktout.$netName[$i]", 'kb/sec', $netTxPkt[$i]/$intSecs);
    }
  }

  if ($graphiteSubsys=~/s/)
  {
    sendData("sockinfo.used",  'sockets', $sockUsed);
    sendData("sockinfo.tcp",   'sockets', $sockTcp);
    sendData("sockinfo.orphan",'sockets', $sockOrphan);
    sendData("sockinfo.tw",    'sockets', $sockTw);
    sendData("sockinfo.alloc", 'sockets', $sockAlloc);
    sendData("sockinfo.mem",   'sockets', $sockMem);
    sendData("sockinfo.udp",   'sockets', $sockUdp);
    sendData("sockinfo.raw",   'sockets', $sockRaw);
    sendData("sockinfo.frag",  'sockets', $sockFrag);
    sendData("sockinfo.fragm", 'sockets', $sockFragM);
  }

  if ($graphiteSubsys=~/t/)
  {
    sendData("tcpinfo.pureack", 'num/sec', $tcpValue[27]/$intSecs);
    sendData("tcpinfo.hpack",   'num/sec', $tcpValue[28]/$intSecs);
    sendData("tcpinfo.loss",    'num/sec', $tcpValue[40]/$intSecs);
    sendData("tcpinfo.ftrans",  'num/sec', $tcpValue[45]/$intSecs);
  }

  if ($graphiteSubsys=~/x/i)
  {
    if ($NumXRails)
    {
      $kbInT=  $elanRxKBTot;
      $pktInT= $elanRxTot;
      $kbOutT= $elanTxKBTot;
      $pktOutT=$elanTxTot;
    }

    if ($NumHCAs)
    {
      $kbInT=  $ibRxKBTot;
      $pktInT= $ibRxTot;
      $kbOutT= $ibTxKBTot;
      $pktOutT=$ibTxTot;
    }
   
    sendData("iconnect.kbin",   'kb/sec',  $kbInT/$intSecs);
    sendData("iconnect.pktin",  'pkt/sec', $pktInT/$intSecs);
    sendData("iconnect.kbout",  'kb/sec',  $kbOutT/$intSecs);
    sendData("iconnect.pktout", 'pkt/sec', $pktOutT/$intSecs);
  }

  if ($graphiteSubsys=~/E/i)
  {
    foreach $key (sort keys %$ipmiData)
    {
      for (my $i=0; $i<scalar(@{$ipmiData->{$key}}); $i++)
      {
        my $name=$ipmiData->{$key}->[$i]->{name};
        my $inst=($key!~/power/ && $ipmiData->{$key}->[$i]->{inst} ne '-1') ? $ipmiData->{$key}->[$i]->{inst} : '';

        sendData("env.$name$inst", $name,  $ipmiData->{$key}->[$i]->{value}, '%s');
      }
    }
  }

  my (@names, @units, @vals);
  for (my $i=0; $i<$impNumMods; $i++) { &{$impPrintExport[$i]}('g', \@names, \@units, \@vals); }
  foreach (my $i=0; $i<scalar(@names); $i++)
  {
    sendData($names[$i], $units[$i], $vals[$i]);
  }
  $graphiteCounter=0    if $graphiteCounter==$graphiteSendCount;
}

# this code tightly synchronized with gexpr and lexpr
sub sendData
{
  my $name=shift;
  my $units=shift;
  my $value=shift;

  # if graphite went away in the middle of an interval there's no point continuing.
  # we're try to reopen it next pass through here
  return    if !defined($graphiteSocket) && !($graphiteDebug & 8);

  # We have to increment at the top since multiple exit points (shame on me) so the
  # very first entry starts at 1 rather than 0;
  $graphiteDataIndex++;
  $value=int($value);

  # These are only undefined the very first time
  if (!defined($graphiteTTL[$graphiteDataIndex]))
  {
    $graphiteTTL[$graphiteDataIndex]=$graphiteTTL;
    $graphiteDataLast[$graphiteDataIndex]=-1;
  }

  # As a minor optimization, only do this when dealing with min/max/avg values
  if ($mmsFlags)
  {
    # And while this should be done in init(), we really don't know how may indexes
    # there are until our first pass through...
    if ($graphiteCounter==1)
    {
      $graphiteDataMin[$graphiteDataIndex]=$graphiteOneTB;
      $graphiteDataMax[$graphiteDataIndex]=0;
      $graphiteDataTot[$graphiteDataIndex]=0;
    }

    $graphiteDataMin[$graphiteDataIndex]=$value    if $graphiteMinFlag && $value<$graphiteDataMin[$graphiteDataIndex];
    $graphiteDataMax[$graphiteDataIndex]=$value    if $graphiteMaxFlag && $value>$graphiteDataMax[$graphiteDataIndex];
    $graphiteDataTot[$graphiteDataIndex]+=$value   if $graphiteAvgFlag;
  }

  return('')    if $graphiteCounter!=$graphiteSendCount;

  #    A c t u a l    S e n d    H a p p e n s    H e r e

  # If doing min/max/avg, reset $value
  if ($graphiteMmaFlags)
  {
    $value=$graphiteDataMin[$graphiteDataIndex]    if $graphiteMinFlag;
    $value=$graphiteDataMax[$graphiteDataIndex]    if $graphiteMaxFlag;
    $value=($grphiteDataTot[$graphiteDataIndex]/$graphiteSendCount)    if $gaphiteAvgFlag;
  }

  # Always send send data if not CO mode, but if so only send when it has
  # indeed changed OR TTL about to expire
  my $valSentFlag=0;
  if (!$graphiteCOFlag || $value!=$graphiteDataLast[$graphiteDataIndex] || $graphiteTTL[$graphiteDataIndex]==1)
  {
    $valSentFlag=1;
    my $message=sprintf("$graphiteMyHost$graphitePost.$name $value %d\n", time);
    print $message    if $graphiteDebug & 1;
    if (!($graphiteDebug & 8))
    {
      my $bytes=syswrite($graphiteSocket, $message, length($message), 0);
    }
    $graphiteDataLast[$graphiteDataIndex]=$value;
  }

  # TTL only applies when in 'CO' mode
  if ($graphiteCOFlag)
  {
    $graphiteTTL[$graphiteDataIndex]--               if !$valSentFlag;
    $graphiteTTL[$graphiteDataIndex]=$graphiteTTL    if $valSentFlag || $graphiteTTL[$graphiteDataIndex]==0;
  }
}

sub openTcpSocket
{
  return   if $graphiteDebug & 8;    # don't open socket

  print "Opening Socket on $graphiteSockHost:$graphiteSockPort\n"    if $graphiteDebug & 16;
  $graphiteSocket=new IO::Socket::INET(
        PeerAddr => $graphiteSockHost,
        PeerPort => $graphiteSockPort,
        Proto    => 'tcp',
        Timeout  => $graphiteTimeout);

  if (!defined($graphiteSocket))
  {
    if (++$graphiteSocketFailCount==$graphiteSocketFailMax)
    {
      logmsg('E', "Could not create socket to $graphiteSockHost:$graphiteSockPort.  Reason: $!");
      $graphiteSocketFailCount=0;
    }
  }
  else
  {
    # we're printing to the term with d=16 because 'I' messages don't go there.
    my $message="Socket opened to graphite/carbon on $graphiteSockHost:$graphiteSockPort";
    print "$message\n"    if $graphiteDebug & 16;
    logmsg('I', $message);
    $graphiteSocketFailCount=0;
  }
}

# This catches the socket failure.  Only problem is it doesn't happen until we try write
# and as a result when we return the write fails with an undef on the socket variable.
# Not really a big deal...
sub graphiteSigPipe
{ 
  undef $graphiteSocket;
}

sub help
{
  my $text=<<EOF;

usage: --export=graphite,host[:port][,options]
  where each option is separated by a comma, noting some take args themselves
    co          only reports changes since last reported value
    d=mask      debugging options, see beginning of graphite.ph for details
    h           print this help and exit
    i=seconds   reporting interval, must be multiple of collect's -i
    p=text      insert this text right after hostname, including '.' if you want one
    s=subsys    only report subsystems, must be a subset of collectl's -s
    ttl=num     if data hasn't changed for this many intervals, report it
                only used with 'co', def=5
    min         report minimal value since last report
    max         report maximum value since last report
    avg         report average of values since last report
EOF

  print $text;
  exit(0);
}

1;
