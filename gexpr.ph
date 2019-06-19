# copyright, 2003-2009 Hewlett-Packard Development Company, LP

#  debug
#    1 - print Var, Units and Values
#    2 - only print sent 'changed' Var/Units/Vales
#    4 - dump packet
#    8 - do not open/use socket (typically used with other flags)
#   16 - print socket open/close info

#  the 'magic' g/G flag
#   -g   ONLY report well-known gangia variables
#   -G   report ALL variables but replace those known by ganglia with their ganglia names

our $gexInterval;

my ($gexSubsys, $gexDebug, $gexCOFlag, $getSendCount, $gexTTL, $gexSocket, $gexPaddr);
my ($gexHost, $gexPort);
my (%gexDataLast, %gexDataMin, %gexDataMax, %gexDataTot, %gexTTL);
my ($gexMinFlag, $gexMaxFlag, $gexAvgFlag, $gexTotFlag)=(0,0,0,0);
my $gexPktSize=1024;
my $gexOneTB=1024*1024*1024*1024;
my $gexCounter=0;
my $gexFlags;
my $gexGFlag=0;
my $gexMcast;
my $gexMcastFlag=0;
my $gexOutputFlag=1;
my $gexColInt;

# This sets a flag as soon as we 'require' the module and tells collectl this
# module does socket communications w/o -A and so is ok to run as daemon
# without requiring -f or -A.
$exportComm |= 1;

sub gexprInit
{
  my $hostport=shift;
  help()    if $hostport eq 'h';

  error('--showcolheader not supported by gexpr')    if $showColFlag;

  # Just like vmstat
  error("-f requires either --rawtoo or -P")     if $filename ne '' && !$rawtooFlag && !$plotFlag;
  error("-P or --rawtoo require -f")             if $filename eq '' && ($rawtooFlag || $plotFlag);

  # If we ever run with a ':' in the inteval, we need to be sure we're
  # only looking at the main one.
  my $gexInterval1=(split(/:/, $interval))[0];

  # Options processing.  must be combo of co, d, i and s (for now)
  $gexDebug=$gexCOFlag=0;
  $gexInterval='';
  $gexSubsys=$subsys;
  $gexTTL=5;

  foreach my $option (@_)
  {
    my ($name, $value)=split(/=/, $option);
    error("invalid gexpr option '$name'")    if $name!~/^[dgGhis]?$|^align|^co$|^ttl$|^min$|^max$|^avg$|^tot$/;

    $gexAlignFlag=1        if $name eq 'align';
    $gexCOFlag=1           if $name eq 'co';
    $gexDebug=$value       if $name eq 'd';
    $gexInterval=$value    if $name eq 'i';
    $gexGFlag+=1           if $name eq 'g';
    $gexGFlag+=2           if $name eq 'G';
    $gexSubsys=$value      if $name eq 's';
    $gexTTL=$value         if $name eq 'ttl';
    $gexMinFlag=1          if $name eq 'min';
    $gexMaxFlag=1          if $name eq 'max';
    $gexAvgFlag=1          if $name eq 'avg';
    $gexTotFlag=1          if $name eq 'tot';

    help()                 if $name eq 'h';
  }

  error("only 1 of 'g' or 'G' with 'gexpr'")                            if $gexGFlag>2;
  error("gexpr does not support standard collectl socket I/O via -A")   if $sockFlag;
  error("host:port must be specified as first parameter")               if !defined($hostport) || $hostport eq '';
  ($gexHost, $gexPort)=split(/:/, $hostport);
  error("the port number must be specified")    if !defined($gexPort) || $gexPort eq '';
  $gexMcastFlag=1    if $gexHost=~/^(\d+)/ && $1>=225 && $1<=239;

  error("gexpr subsys options '$gexSubsys' not a proper subset of '$subsys'")
        if $subsys ne '' && $gexSubsys ne '' && $gexSubsys!~/^[$subsys]+$/;

  $gexColInt=(split(/:/, $interval))[0];
  $gexInterval=$gexColInt    if $gexInterval eq '';

  # convert to the number of samples we want to send
  $gexSendCount=int($gexInterval/$gexColInt);
  error("gexpr interval of '$gexInterval' is not a multiple of '$gexColInt' seconds")
	if $gexColInt*$gexSendCount != $gexInterval;

  $gexFlags=$gexMinFlag+$gexMaxFlag+$gexAvgFlag+$gexTotFlag;
  error("only 1 of 'min', 'max', 'avg' or 'tot' with 'gexpr'")    if $gexFlags>1;
  error("'min', 'max', 'avg' & 'tot' require gexpr 'i' that is > collectl's -i")
        if $gexFlags && $gexSendCount==1;

  if ($gexAlignFlag)
  {
    my $div1=int(60/$gexColInt);
    my $div2=int($gexColInt/60);
    error("'align' requires collectl interval be a factor or multiple of 60 seconds")
      		 if ($gexColInt<=60 && $div1*$gexColInt!=60) || ($gexColInt>60 && $div2*60!=$gexColInt);
    error("'align' only makes sense when multiple samples/interval")    if $gexInterval<=$gexColInt;
    error("'lexpr,align' requires -D or --align")                       if !$gexAlignFlag && !$daemonFlag;
  }

  # Since gexpr DOES write over a socket but does not use -A, make sure the default
  # behavior for -f logs matches that of -A
  $rawtooFlag=1    if $filename ne '' && !$plotFlag;

  #    O p e n    S o c k e t

  if (!$gexMcastFlag)
  {
    openSocket($gexHost, $gexPort);
  }
  else
  {
    error("must install IO::Socket::Multcast to use multicast feature")
	if !eval {require "IO/Socket/Multicast.pm"};
    $gexMcast = IO::Socket::Multicast->new() or die "create group";
  }
}

sub gexpr
{
  # if not time to print and we're not doing min/max/avg/tot, there's nothing to do.
  # BUT always make sure time aligns to top of minute based on i=
  $gexCounter++;
  $gexOutputFlag=(($gexCounter % $gexSendCount) == 0) ? 1 : 0              if !$gexAlignFlag;
  $gexOutputFlag=(!(int($lastSecs[$rawPFlag]) % $gexInterval)) ? 1 : 0     if  $gexAlignFlag;
  return    if (!$gexOutputFlag && $gexFlags==0);

  if ($gexSubsys=~/c/i)
  {
    if ($gexSubsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;

      if ($gexGFlag)    # for both 'g' OR 'G'
      {
        sendData('cpu_user',   'percent', $userP[$i], 'cpu');
        sendData('cpu_nice',   'percent', $niceP[$i], 'cpu');
        sendData('cpu_system', 'percent', $sysP[$i],  'cpu');
        sendData('cpu_wio',    'percent', $waitP[$i], 'cpu');
        sendData('cpu_idle',   'percent', $idleP[$i], 'cpu');

        sendData('cpu_num',      'CPUs',       $NumCpus,   'cpu');
        sendData('proc_total',   'Load/Procs', $loadQue,   'cpu');
        sendData('proc_run',     'Load/Procs', $loadRun,   'cpu');
        sendData('load_one',     'Load/Procs', $loadAvg1,  'cpu');
        sendData('load_five',    'Load/Procs', $loadAvg5,  'cpu');
        sendData('load_fifteen', 'Load/Procs', $loadAvg15, 'cpu');
      }

      if (!$gexGFlag)      # if not 'g' use standard collectl names
      {
        sendData('cputotals.user', 'percent', $userP[$i], 'cpu');
        sendData('cputotals.nice', 'percent', $niceP[$i], 'cpu');
        sendData('cputotals.sys',  'percent', $sysP[$i],  'cpu');
        sendData('cputotals.wait', 'percent', $waitP[$i], 'cpu');
        sendData('cputotals.idle', 'percent', $idleP[$i], 'cpu');
      }

      if ($gexGFlag!=1)    # 'G' or nothing
      {
        sendData('cputotals.irq',  'percent', $irqP[$i],   'cpu');
        sendData('cputotals.soft', 'percent', $softP[$i],  'cpu');
        sendData('cputotals.steal','percent', $stealP[$i], 'cpu');

        sendData('ctxint.ctx',  'switches/sec', $ctxt/$intSecs,   'cpu');
        sendData('ctxint.int',  'intrpts/sec',  $intrpt/$intSecs, 'cpu');
        sendData('ctxint.proc', 'pcreates/sec', $proc/$intSecs,   'cpu');
        sendData('ctxint.runq', 'runqSize',     $loadQue,         'cpu');
      }

      if (!$gexGFlag)       # do it again so that we report ALL cpu %s together
      {
        sendData('cpuload.avg1',   'loadAvg1',  $loadAvg1,  'cpu');
        sendData('cpuload.avg5',   'loadAvg5',  $loadAvg5,  'cpu');
        sendData('cpuload.avg15',  'loadAvg15', $loadAvg15, 'cpu');
      }
    }

    if ($gexSubsys=~/C/)
    {
      for (my $i=0; $i<$NumCpus; $i++)
      {
        sendData("cpuinfo.user.cpu$i",  'percent', $userP[$i],     'cpu');
        sendData("cpuinfo.nice.cpu$i",  'percent', $niceP[$i],     'cpu');
        sendData("cpuinfo.sys.cpu$i",   'percent', $sysP[$i],      'cpu');
        sendData("cpuinfo.wait.cpu$i",  'percent', $waitP[$i],     'cpu');
        sendData("cpuinfo.irq.cpu$i",   'percent', $irqP[$i],      'cpu');
        sendData("cpuinfo.soft.cpu$i",  'percent', $softP[$i],     'cpu');
        sendData("cpuinfo.steal.cpu$i", 'percent', $stealP[$i],    'cpu');
        sendData("cpunifo.idle.cpu$i",  'percent', $idleP[$i],     'cpu');
        sendData("cpuinfo.intrpt.cpu$i",'percent', $intrptTot[$i], 'cpu');
      }
    }
  }

  if ($gexSubsys=~/d/i && $gexGFlag!=1)
  {
    if ($gexSubsys=~/d/)
    {
      sendData('disktotals.reads',    'reads/sec',    $dskReadTot/$intSecs,    'disk');
      sendData('disktotals.readkbs',  'readkbs/sec',  $dskReadKBTot/$intSecs,  'disk');
      sendData('disktotals.writes',   'writes/sec',   $dskWriteTot/$intSecs,   'disk');
      sendData('disktotals.writekbs', 'writekbs/sec', $dskWriteKBTot/$intSecs, 'disk');
    }

    if ($gexSubsys=~/D/)
    {
      for (my $i=0; $i<@dskOrder; $i++)
      {
        # preserve display order but skip any disks not seen this interval
        $dskName=$dskOrder[$i];
        next    if !defined($dskSeen[$i]);
        next    if ($dskFiltKeep eq '' && $dskName=~/$dskFiltIgnore/) || ($dskFiltKeep ne '' && $dskName!~/$dskFiltKeep/);

        sendData("diskinfo.reads.$dskName",    'reads/sec',    $dskRead[$i]/$intSecs,    'disk');
        sendData("diskinfo.readkbs.$dskName",  'readkbs/sec',  $dskReadKB[$i]/$intSecs,  'disk');
        sendData("diskinfo.writes.$dskName",   'writes/sec',   $dskWrite[$i]/$intSecs,   'disk');
        sendData("diskinfo.writekbs.$dskName", 'writekbs/sec', $dskWriteKB[$i]/$intSecs, 'disk');
      }
    }
  }

  if ($gexSubsys=~/f/ && $gexGFlag!=1)
  {
    if ($nfsSFlag)
    {
      sendData('nfsinfo.SRead',   'SvrReads/sec',  $nfsSReadsTot/$intSecs,  'NFS server');
      sendData('nfsinfo.SWrite',  'SvrWrites/sec', $nfsSWritesTot/$intSecs, 'NFS server');
      sendData('nfsinfo.Smeta',   'SvrMeta/sec',   $nfsSMetaTot/$intSecs,   'NFS server');
      sendData('nfsinfo.Scommit', 'SvrCommt/sec' , $nfsSCommitTot/$intSecs, 'NFS server');
    }
    if ($nfsCFlag)
    {
      sendData('nfsinfo.CRead',   'CltReads/sec',  $nfsCReadsTot/$intSecs,  'NFS client');
      sendData('nfsinfo.CWrite',  'CltWrites/sec', $nfsCWritesTot/$intSecs, 'NFS client');
      sendData('nfsinfo.Cmeta',   'CltMeta/sec',   $nfsCMetaTot/$intSecs,   'NFS client');
      sendData('nfsinfo.Ccommit', 'CltCommt/sec' , $nfsCCommitTot/$intSecs, 'NFS client');
    }
  }

  if ($gexSubsys=~/i/ && $gexGFlag!=1)
  {
    sendData('inodeinfo.dentnum',    'dentrynum',    $dentryNum,    'inode');
    sendData('inodeinfo.dentunused', 'dentryunused', $dentryUnused, 'inode');
    sendData('inodeinfo.fhandalloc', 'filesalloc',   $filesAlloc,   'inode');
    sendData('inodeinfo.fhandmpct',  'filesmax',     $filesMax,     'inode');
    sendData('inodeinfo.inodenum',   'inodeused',    $inodeUsed,    'inode');
  }

  if ($gexSubsys=~/l/ && $gexGFlag!=1)
  {
    if ($CltFlag)
    {
      sendData('lusclt.reads',    'reads/sec',    $lustreCltReadTot/$intSecs,    'Lustre client');
      sendData('lusclt.readkbs',  'readkbs/sec',  $lustreCltReadKBTot/$intSecs,  'Lustre client');
      sendData('lusclt.writes',   'writes/sec',   $lustreCltWriteTot/$intSecs,   'Lustre client');
      sendData('lusclt.writekbs', 'writekbs/sec', $lustreCltWriteKBTot/$intSecs, 'Lustre client');
      sendData('lusclt.numfs',    'filesystems',  $NumLustreFS,                  'Lustre client');
    }

    if ($MdsFlag)
    {
      my $getattrPlus=$lustreMdsGetattr+$lustreMdsGetattrLock+$lustreMdsGetxattr;
      my $setattrPlus=$lustreMdsReintSetattr+$lustreMdsSetxattr;
      my $varName=($cfsVersion lt '1.6.5') ? 'reint' : 'unlink';
      my $varVal= ($cfsVersion lt '1.6.5') ? $lustreMdsReint : $lustreMdsReintUnlink;
      my $varTitle = ($cfsVersion lt '1.6.5') ? 'Delete/Set Attr.' : 'File/Dir Deletes';
      sendData('lusmds.gattrP',    'gattrP/sec',   $getattrPlus/$intSecs,   'Lustre MDS', 'Get Attributes');
      sendData('lusmds.sattrP',    'sattrP/sec',   $setattrPlus/$intSecs,   'Lustre MDS', 'Set Attributes');
      sendData('lusmds.sync',      'sync/sec',     $lustreMdsSync/$intSecs, 'Lustre MDS', 'File Syncs');
      sendData("lusmds.$varName",  "$varName/sec", $varVal/$intSecs,        'Lustre MDS', '$varTitle');
    }

    if ($OstFlag)
    {
      sendData('lusost.reads',    'reads/sec',    $lustreReadOpsTot/$intSecs,     'Lustre OST');
      sendData('lusost.readkbs',  'readkbs/sec',  $lustreReadKBytesTot/$intSecs,  'Lustre OST');
      sendData('lusost.writes',   'writes/sec',   $lustreWriteOpsTot/$intSecs,    'Lustre OST');
      sendData('lusost.writekbs', 'writekbs/sec', $lustreWriteKBytesTot/$intSecs, 'Lustre OST');
    }
  }

  if ($gexSubsys=~/L/ && $gexGFlag!=1)
  {
    if ($CltFlag)
    {
      # Either report details by filesystem OR OST
      if ($lustOpts!~/O/)
      {
        for (my $i=0; $i<$NumLustreFS; $i++)
        {
          sendData("lusost.reads.$lustreCltFS[$i]",    'reads/sec',    $lustreCltRead[$i]/$intSecs,    'Lustre client');
	  sendData("lusost.readkbs.$lustreCltFS[$i]",  'readkbs/sec',  $lustreCltReadKB[$i]/$intSecs,  'Lustre client');
          sendData("lusost.writes.$lustreCltFS[$i]",   'writes/sec',   $lustreCltWrite[$i]/$intSecs,   'Lustre client');
          sendData("lusost.writekbs.$lustreCltFS[$i]", 'writekbs/sec', $lustreCltWriteKB[$i]/$intSecs, 'Lustre client');
        }
      }
      else
      {
        for (my $i=0; $i<$NumLustreCltOsts; $i++)
        {
          sendData("lusost.reads.$lustreCltOsts[$i]",    'reads/sec',    $lustreCltLunRead[$i]/$intSecs,    'Lustre client');
          sendData("lusost.readkbs.$lustreCltOsts[$i]",  'readkbs/sec',  $lustreCltLunReadKB[$i]/$intSecs,  'Lustre client');
          sendData("lusost.writes.$lustreCltOsts[$i]",   'writes/sec',   $lustreCltLunWrite[$i]/$intSecs,   'Lustre client');
          sendData("lusost.writekbs.$lustreCltOsts[$i]", 'writekbs/sec', $lustreCltLunWriteKB[$i]/$intSecs, 'Lustre client');
        }
      }
    }

    if ($OstFlag)
    {
      for ($i=0; $i<$NumOst; $i++)
      {
        sendData("lusost.reads.$lustreOsts[$i]",    'reads/sec',    $lustreReadOps[$i]/$intSecs,     'Lustre OST');
        sendData("lusost.readkbs.$lustreOsts[$i]",  'readkbs/sec',  $lustreReadKBytes[$i]/$intSecs,  'Lustre OST');
        sendData("lusost.writes.$lustreOsts[$i]",   'writes/sec',   $lustreWriteOps[$i]/$intSecs,    'Lustre OST');
        sendData("lusost.writekbs.$lustreOsts[$i]", 'writekbs/sec', $lustreWriteKBytes[$i]/$intSecs, 'Lustre OST');
      }
    }
  }

  if ($gexSubsys=~/m/)
  {
    if ($gexGFlag)       # 'g' or 'G'
    {
      sendData('mem_total',     'Bytes',         $memTot,    'memory');
      sendData('mem_free',      'Bytes',         $memFree,   'memory');
      sendData('mem_shared',    'Bytes',         $memShared, 'memory');
      sendData('mem_buffers',  'Bytes',          $memBuf,    'memory');
      sendData('mem_cached',    'Bytes',         $memCached, 'memory');
      sendData('swap_total',    'Bytes',         $swapTotal, 'memory');
      sendData('swap_free',     'Bytes',         $swapFree,  'memory');
    }

    if (!$gexGFlag)       # neither
    {
      sendData('meminfo.tot',       'kb',         $memTot,    'memory');
      sendData('meminfo.free',      'kb',         $memFree,   'memory');
      sendData('meminfo.shared',    'kb',         $memShared, 'memory');
      sendData('meminfo.buf',       'kb',         $memBuf,    'memory');
      sendData('meminfo.cached',    'kb',         $memCached, 'memory');
      sendData('swapinfo.total',    'kb',         $swapTotal, 'memory');
      sendData('swapinfo.free',     'kb',         $swapFree,  'memory');
    }

    if ($gexGFlag!=1)     # nothing or 'G'
    {
      sendData('meminfo.used',      'kb',         $memUsed,               'memory');
      sendData('meminfo.slab',      'kb',         $memSlab,               'memory');
      sendData('meminfo.map',       'kb',         $memMap,                'memory');
      sendData('meminfo.hugetot',   'kb',         $memHugeTot,            'memory');
      sendData('meminfo.hugefree',  'kb',         $memHugeFree,           'memory');
      sendData('meminfo.hugersvd',  'kb',         $memHugeRsvd,           'memory');
      sendData('swapinfo.used',     'kb',         $swapUsed,              'memory');
      sendData('swapinfo.in',       'swaps/sec',  $swapin/$intSecs,       'memory');
      sendData('swapinfo.out',      'swaps/sec',  $swapout/$intSecs,      'memory');
      sendData('pageinfo.fault',    'faults/sec', $pagefault/$intSecs,    'memory');
      sendData('pageinfo.majfault', 'majflt/sec', $pagemajfault/$intSecs, 'memory');
      sendData('pageinfo.in',       'pages/sec',  $pagein/$intSecs,       'memory');
      sendData('pageinfo.out',      'pages/sec',  $pageout/$intSecs,      'memory');
    }
  }

  # gexFlag doesn't apply
  if ($gexSubsys=~/M/)
  {
    for (my $i=0; $i<$CpuNodes; $i++)
    {
      foreach my $field ('used', 'free', 'slab', 'map', 'anon', 'lock', 'act', 'inact')
      {
        sendData("numainfo.$field.$i", 'kb', $numaMem[$i]->{$field}, 'memory');
      }
    }
  }

  if ($gexSubsys=~/n/i)
  {
    if ($gexSubsys=~/n/)
    {
      if ($gexGFlag)       # 'g' or 'G'
      {
        sendData('bytes_in',  'Bytes/sec', $netRxKBTot*1024/$intSecs, 'network');
        sendData('bytes_out', 'Bytes/sec', $netTxKBTot*1024/$intSecs, 'network');
        sendData('pkts_in',   'pkts/sec', $netRxPktTot/$intSecs,      'network');
        sendData('pkts_out',  'pkts/sec', $netTxPktTot/$intSecs,      'network');
      }
      else                 # neither
      {
        sendData('nettotals.kbin',   'kb/sec', $netRxKBTot/$intSecs,    'network');
        sendData('nettotals.pktin',  'pkts/sec', $netRxPktTot/$intSecs, 'network');
        sendData('nettotals.kbout',  'kb/sec', $netTxKBTot/$intSecs,    'network');
        sendData('nettotals.pktout', 'pkts/sec', $netTxPktTot/$intSecs, 'network');
      }
    }

    if ($gexSubsys=~/N/)
    {
      for ($i=0; $i<@netOrder; $i++)
      {
        $netName=$netOrder[$i];
        next    if !defined($netSeen[$i]);
        next    if ($netFiltKeep eq '' && $netName=~/$netFiltIgnore/) || ($netFiltKeep ne '' && $netName!~/$netFiltKeep/);
        next    if $netName=~/lo|sit/;

        sendData("nettotals.kbin.$netName",   'kb/sec', $netRxKB[$i]/$intSecs,    'network');
        sendData("nettotals.pktin.$netName",  'pkts/sec', $netRxPkt[$i]/$intSecs, 'network');
        sendData("nettotals.kbout.$netName",  'kb/sec', $netTxKB[$i]/$intSecs,    'network');
        sendData("nettotals.pktout.$netName", 'pkts/sec', $netTxPkt[$i]/$intSecs, 'network');
      }
    }
  }

  if ($gexSubsys=~/s/ && $gexGFlag!=1)
  {
    sendData("sockinfo.used",  'sockets', $sockUsed,   'socket');
    sendData("sockinfo.tcp",   'sockets', $sockTcp,    'socket');
    sendData("sockinfo.orphan",'sockets', $sockOrphan, 'socket');
    sendData("sockinfo.tw",    'sockets', $sockTw,     'socket');
    sendData("sockinfo.alloc", 'sockets', $sockAlloc,  'socket');
    sendData("sockinfo.mem",   'sockets', $sockMem,    'socket');
    sendData("sockinfo.udp",   'sockets', $sockUdp,    'socket');
    sendData("sockinfo.raw",   'sockets', $sockRaw,    'socket');
    sendData("sockinfo.frag",  'sockets', $sockFrag,   'socket');
    sendData("sockinfo.fragm", 'sockets', $sockFragM,  'socket');
  }

  if ($gexSubsys=~/t/ && $gexGFlag!=1)
  {
    sendData("tcpinfo.iperrs",   'num/sec', $ipErrors/$intSecs,    'tcp')    if $tcpFilt=~/i/;
    sendData("tcpinfo.tcperrs",  'num/sec', $tcpErrors/$intSecs,   'tcp')    if $tcpFilt=~/t/;
    sendData("tcpinfo.udperrs",  'num/sec', $udpErrors/$intSecs,   'tcp')    if $tcpFilt=~/u/;
    sendData("tcpinfo.icmperrs", 'num/sec', $icmpErrors/$intSecs,  'tcp')    if $tcpFilt=~/c/;
    sendData("tcpinfo.tcpxerrs", 'num/sec', $tcpExErrors/$intSecs, 'tcp')    if $tcpFilt=~/T/;

  }

  if ($gexSubsys=~/x/i && $gexGFlag!=1)
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
   
    sendData("iconnect.kbin",   'kb/sec',  $kbInT/$intSecs,   'infiniband', 'Data Received');
    sendData("iconnect.pktin",  'pkt/sec', $pktInT/$intSecs,  'infiniband', 'Packets Received');
    sendData("iconnect.kbout",  'kb/sec',  $kbOutT/$intSecs,  'infiniband', 'Data Transmitted');
    sendData("iconnect.pktout", 'pkt/sec', $pktOutT/$intSecs, 'infiniband', 'Packets Transmitted');
  }

  if ($gexSubsys=~/E/i && $gexGFlag!=1)
  {
    foreach $key (sort keys %$ipmiData)
    {
      for (my $i=0; $i<scalar(@{$ipmiData->{$key}}); $i++)
      {
        my $name=$ipmiData->{$key}->[$i]->{name};
        my $inst=($key!~/power/ && $ipmiData->{$key}->[$i]->{inst} ne '-1') ? $ipmiData->{$key}->[$i]->{inst} : '';

        sendData("env.$name$inst", $name,  $ipmiData->{$key}->[$i]->{value}, 'IPMI');
      }
    }
  }

  # if any imported data, it may want to include gexpr output.  However this means getting a list of
  # 3-tuples to call OUR formatting routines with so the import module doesn't have to.
  # NOTE - the assumption is no ganglia specific counters.  If there ever are, we'll need to remove
  #        restriction and ALL imports will have to deal with $gexFlag if called from here
  if ($gexGFlag!=1)
  {
    my (@names, @units, @vals, @groups, @titles);
    for (my $i=0; $i<$impNumMods; $i++) { &{$impPrintExport[$i]}('g', \@names, \@units, \@vals, \@groups, \@titles); }
    foreach (my $i=0; $i<scalar(@names); $i++)
    {
      sendData($names[$i], $units[$i], $vals[$i], $groups[$i], $titles[$i]);
    }
  }
  $gexCounter=0    if $gexOutputFlag;
}

sub openSocket
{
  my $host=shift;
  my $port=shift;

  print "Opening Socket on $host:$port\n"    if $gexDebug & 16;
  my $iaddr = inet_aton($host)          or logmsg('F', "Couldn't get address for '$host'");
  $gexPaddr = sockaddr_in($port,$iaddr) or logmsg('F', "Couldn't convert address for '$host'");
  my $proto = getprotobyname('udp')     or logmsg('F', "Couldn't getprotbyname for '$host'");

  socket($gexSocket, PF_INET, SOCK_DGRAM, $proto) or logmdg('F', "Couldn't open UDP socket");
  print "Opened\n"    if $gexDebug & 16;
}

# this code tightly synchronized with lexpr and graphite
sub sendData
{

  my $name=shift;
  my $units=shift;
  my $value=shift;
  my $group=shift;
  my $title=shift;

  $value=int($value);

  # These are only undefined the very first time
  if (!defined($gexTTL{$name}))
  {
    $gexTTL{$name}=$gexTTL;
    $gexDataLast{$name}=-1;
  }

  # As a minor optimization, only do this when dealing with min/max/avg/tot values
  if ($gexFlags)
  {
    # And while this should be done in init(), we really don't know how may indexes
    # there are until our first pass through...
    if ($gexCounter==1)
    {
      $gexDataMin{$name}=$gexOneTB;
      $gexDataMax{$name}=0;
      $gexDataTot{$name}=0;
    }

    $gexDataMin{$name}=$value    if $gexMinFlag && $value<$gexDataMin{$name};
    $gexDataMax{$name}=$value    if $gexMaxFlag && $value>$gexDataMax{$name};
    $gexDataTot{$name}+=$value   if $gexAvgFlag || $gexTotFlag;
  }

  return('')    if !$gexOutputFlag;

  #    A c t u a l    S e n d    H a p p e n s    H e r e

  # If doing min/max/avg, reset $value
  if ($gexFlags)
  {
    $value=$gexDataMin{$name}                    if $gexMinFlag;
    $value=$gexDataMax{$name}                    if $gexMaxFlag;
    $value=$gexDataTot{$name}                    if $gexTotFlag;
    $value=($gexDataTot{$name}/$gexCounter)      if $gexAvgFlag;
  }

  # Always send send data if not CO mode,but if so only send when it has
  # indeed changed OR TTL about to expire
  my $valSentFlag=0;
  if (!$gexCOFlag || $value!=$gexDataLast{$name} || $gexTTL{$name}==1)
  {
    $valSentFlag=1;
    sendMetaPacket($name, $units, $group, $title);
    sendDataPacket($name, $value);
    $gexDataLast{$name}=$value;
  }

  # A fair chunk of work, but worth it
  if ($gexDebug & 3)
  {
    my ($intSeconds, $intUsecs);
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

    $intUsecs=sprintf("%06d", $intUsecs);
    my ($sec, $min, $hour)=localtime($intSeconds);
    my $timestamp=sprintf("%02d:%02d:%02d.%s", $hour, $min, $sec, substr($intUsecs, 0, 3));
    printf "$timestamp Name: %-25s Units: %-12s Val: %8d Group: %-10s TTL: %3d Title: %-20s %s\n",
                $name, $units, $value,
		defined($group) ? $group : '-',
		$gexTTL{$name},
		defined($title) ? $title : '-',
		($valSentFlag) ? 'sent' : ''
                        if $gexDebug & 1 || $valSentFlag;
  }

  # TTL only applies when in 'CO' mode, noting we already made expiration
  # decision above when we saw counter of 1
  if ($gexCOFlag)
  {
    $gexTTL{$name}--          if !$valSentFlag;
    $gexTTL{$name}=$gexTTL    if $valSentFlag || $gexTTL{$name}==0;
  }
}

sub sendMetaPacket
{
  my $name= shift;
  my $units=shift;
  my $group=shift;
  my $title=shift;

  my $numOptArgs=0;
  $numOptArgs++    if defined($group);
  $numOptArgs++    if defined($title);

  my $string='';
  $string.=pack('N', 0x80);
  $string.=pack('N', length($myHost));
  $string.=packString($myHost);
  $string.=pack('N', length($name));
  $string.=packString($name);
  $string.=pack('N', 0);                # spoof
  $string.=pack('N', length('double'));
  $string.=packString('double');

  $string.=pack('N', length($name));
  $string.=packString($name);

  $string.=pack('N', length($units));
  $string.=packString($units);

  $string.=pack('N', 3);                        # slope
  $string.=pack('N', 2*$gexTTL*$gexInterval);   # time to live
  $string.=pack('N', 4*$gexTTL*$gexInterval);   # dmax

  $string.=pack('N', $numOptArgs);
  if (defined($group))
  {
    $string.=pack('N', length('GROUP'));
    $string.=packString('GROUP');
    $string.=pack('N', length($group));
    $string.=packString($group)
  }

  if (defined($title))
  {
    $string.=pack('N', length('TITLE'));
    $string.=packString('TITLE');
    $string.=pack('N', length($title));
    $string.=packString($title);
  }

  sendUDP($string);
}

sub sendDataPacket
{
  my $name= shift;
  my $value=shift;

  my $string='';
  $string.=pack('N', 0x85);
  $string.=pack('N', length($myHost));
  $string.=packString($myHost);
  $string.=pack('N', length($name));
  $string.=packString($name);
  $string.=pack('N', 0);
  $string.=pack('N', 2);
  $string.=packString("%s");
  $string.=pack('N', length($value));
  $string.=packString($value);

  sendUDP($string);
}
sub sendUDP
{
  my $data=shift;

  dumpUDP($data)    if $gexDebug & 4;
  return            if $gexDebug & 8;

  my $length=length($data);
  for (my $offset=0; $length>0; )
  {
    # Either send as regular UDP packet(s) OR send to the multicast address
    my $bytes=(!$gexMcastFlag) ? send($gexSocket, substr($data, $offset, $gexPktSize), 0, $gexPaddr) :
				 $gexMcast->mcast_send($data, "$gexHost:$gexPort");
    if (!defined($bytes))
    {
      print "Error: '$!' writing to socket";
      last;
    }
    $offset+=$bytes;
    $length-=$bytes;
  }
}

sub packString
{
  my $string=shift;
  my $pad=4-(length($string) % 4);
  $pad=0    if $pad==4;

  for (my $i=0; $i<$pad; $i++)
  {
    $string.=pack('c', 0);
  }
  return($string);
}

sub dumpUDP
{
  my $output=shift;

  for (my $i=0; $i<length($output); $i++)
  {
    my $byte=unpack('C', substr($output, $i, 1));
    printf "%02x ", $byte;
#    print "\n"    if $i % 4 == 3;
  }
  print "\n";
}

sub help
{
  my $text=<<EOF;

usage: --export=gexpr,host:port[,options]
  where each option is separated by a comma, noting some take args themselves
    align       align output to whole minute boundary
    co          only reports changes since last reported value
    d=mask      debugging options, see beginning of graphite.ph for details
    h           print this help and exit
    g           only report 'standard' ganglia variables/names
    G           report 'standard' names plus any additional collectl data
    i=seconds   reporting interval, must be multiple of collect's -i
    s=subsys    only report subsystems, must be a subset of collectl's -s
    ttl=num     if data hasn't changed for this many intervals, report it
                only used with 'co', def=5
    avg         report average of values since last report
    max         report maximum value since last report
    min         report minimal value since last report
    tot		report total values (as makes sense) since last report
EOF

  print $text;
  exit(0);
}

1;
