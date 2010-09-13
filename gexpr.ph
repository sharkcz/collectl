# copyright, 2003-2009 Hewlett-Packard Development Company, LP

#  debug
#    1 - print Var, Units and Values
#    2 - only print sent 'changed' Var/Units/Vales
#    4 - dump packet
#    8 - do not open/use socket (typically used with other flags)
#   16 - print socket open/close info

my ($gexSubsys, $gexInterval, $gexDebug, $gexCOFlag, $gexTTL, $gexSocket, $gexPaddr);
my ($gexHost, $gexPort, $gexDataIndex, @gexDataLast, @gexTTL);
my ($gexMinFlag, $gexMaxFlag, $gexAvgFlag)=(0,0,0);
my $gexPktSize=1024;
my $gexOneTB=1024*1024*1024*1024;
my $gexCounter=0;
my $gexFlags;
my $gexMcast;
my $gexMcastFlag=0;
sub gexprInit
{
  my $hostport=shift;

  # If we ever run with a ':' in the inteval, we need to be sure we're
  # only looking at the main one.
  my $gexInterval1=(split(/:/, $interval))[0];

  # Options processing.  must be combo of co, d, i and s (for now)
  $gexDebug=$gexCOFlag=0;
  $gexInterval=$gexInterval1;
  $gexSubsys=$subsys;
  $gexTTL=5;
  foreach my $option (@_)
  {
    my ($name, $value)=split(/=/, $option);
    error("invalid gexpr option '$name'")    if $name!~/^[dis]?$|^co$|^ttl$|^min$|^max$|^avg$/;

    $gexCOFlag=1           if $name eq 'co';
    $gexDebug=$value       if $name eq 'd';
    $gexInterval=$value    if $name eq 'i';
    $gexSubsys=$value      if $name eq 's';
    $gexTTL=$value         if $name eq 'ttl';
    $gexMinFlag=1          if $name eq 'min';
    $gexMaxFlag=1          if $name eq 'max';
    $gexAvgFlag=1          if $name eq 'avg';
  }

  error("gexpr does not support standard collectl socket I/O via -A")   if $sockFlag;
  error("host:port must be specified as first parameter")               if !defined($hostport) || $hostport eq '';
  ($gexHost, $gexPort)=split(/:/, $hostport);
  error("the port number must be specified")    if !defined($gexPort) || $gexPort eq '';
  $gexMcastFlag=1    if $gexHost=~/^(\d+)/ && $1>=225 && $1<=239;

  error("gexpr subsys options '$gexSubsys' not a proper subset of '$subsys'")
        if $subsys ne '' && $gexSubsys!~/^[$subsys]+$/;

  # convert to the number of samples we want to send
  $gexSendCount=int($gexInterval/$gexInterval1);
  error("gexpr interval option not a multiple of '$lexInterval1' seconds")
	if $gexInterval1*$gexSendCount != $gexInterval;

  $gexFlags=$gexMinFlag+$gexMaxFlag+$gexAvgFlag;
  error("only 1 of 'min', 'max' or 'avg' with 'gexpr'")    if $gexFlags>1;
  error("'min', 'max' and 'avg' require gexpr 'i' that is > collectl's -i")
        if $gexFlags && $gexSendCount==1;

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
  # if not time to print and we're not doing min/max/tot, there's nothing to do.
  $gexCounter++;
  return    if ($gexCounter!=$gexSendCount && $gexFlags==0);

  # We ALWAYS process the same number of data elements for any collectl instance
  # so we can use a global index to point to the one we're currently using.
  $gexDataIndex=0;

  if ($gexSubsys=~/c/i)
  {
    if ($gexSubsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;
      sendData('cputotals.user', 'percent', $userP[$i]);
      sendData('cputotals.nice', 'percent', $niceP[$i]);
      sendData('cputotals.sys',  'percent', $sysP[$i]);
      sendData('cputotals.wait', 'percent', $waitP[$i]);
      sendData('cputotals.irq',  'percent', $irqP[$i]);
      sendData('cputotals.soft', 'percent', $softP[$i]);
      sendData('cputotals.steal','percent', $stealP[$i]);
      sendData('cputotals.idle', 'percent', $idleP[$i]);

      sendData('ctxint.ctx',  'switches/sec', $ctxt/$intSecs);
      sendData('ctxint.int',  'intrpts/sec',  $intrpt/$intSecs);
      sendData('ctxint.proc', 'pcreates/sec', $proc/$intSecs);
      sendData('ctxint.runq', 'runqSize',     $loadQue);
    }

    if ($gexSubsys=~/C/)
    {
      for (my $i=0; $i<$NumCpus; $i++)
      {
        sendData("cputotals.user.cpu$i",  'percent', $userP[$i]);
        sendData("cputotals.nice.cpu$i",  'percent', $niceP[$i]);
        sendData("cputotals.sys.cpu$i",   'percent', $sysP[$i]);
        sendData("cputotals.wait.cpu$i",  'percent', $waitP[$i]);
        sendData("cputotals.irq.cpu$i",   'percent', $irqP[$i]);
        sendData("cputotals.soft.cpu$i",  'percent', $softP[$i]);
        sendData("cputotals.steal.cpu$i", 'percent', $stealP[$i]);
        sendData("cputotals.idle.cpu$i",  'percent', $idleP[$i]);
        sendData("cputotals.intrpt.cpu$i",'percent', $intrptTot[$i]);
      }
    }
  }

  if ($gexSubsys=~/d/i)
  {
    if ($gexSubsys=~/d/)
    {
      sendData('disktotals.reads',    'reads/sec',    $dskReadTot/$intSecs);
      sendData('disktotals.readkbs',  'readkbs/sec',  $dskReadKBTot/$intSecs);
      sendData('disktotals.writes',   'writes/sec',   $dskWriteTot/$intSecs);
      sendData('disktotals.writekbs', 'writekbs/sec', $dskWriteKBTot/$intSecs);
    }

    if ($gexSubsys=~/D/)
    {
      for (my $i=0; $i<$NumDisks; $i++)
      {
        sendData("diskinfo.reads.$dskName[$i]",    'reads/sec',    $dskRead[$i]/$intSecs);
        sendData("diskinfo.readkbs.$dskName[$i]",  'readkbs/sec',  $dskReadKB[$i]/$intSecs);
        sendData("diskinfo.writes.$dskName[$i]",   'writes/sec',   $dskWrite[$i]/$intSecs);
        sendData("diskinfo.writekbs.$dskName[$i]", 'writekbs/sec', $dskWriteKB[$i]/$intSecs);
      }
    }
  }

  if ($gexSubsys=~/f/)
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

  if ($gexSubsys=~/i/)
  {
    sendData('inodeinfo.dentnum',    'dentrynum',    $dentryNum);
    sendData('inodeinfo.dentunused', 'dentryunused', $dentryUnused);
    sendData('inodeinfo.fhandalloc', 'filesalloc',   $filesAlloc);
    sendData('inodeinfo.fhandmpct',  'filesmax',     $filesMax);
    sendData('inodeinfo.inodenum',   'inodeused',    $inodeUsed);
  }

  if ($gexSubsys=~/l/)
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

  if ($gexSubsys=~/L/)
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

  if ($gexSubsys=~/m/)
  {
    sendData('meminfo.tot',       'kb',         $memTot);
    sendData('meminfo.used',      'kb',         $memUsed);
    sendData('meminfo.free',      'kb',         $memFree);
    sendData('meminfo.shared',    'kb',         $memShared);
    sendData('meminfo.buf',       'kb',         $memBuf);
    sendData('meminfo.cached',    'kb',         $memCached);
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

  if ($gexSubsys=~/n/i)
  {
    if ($gexSubsys=~/n/)
    {
      sendData('nettotals.kbin',   'kb/sec', $netRxKBTot/$intSecs);
      sendData('nettotals.pktin',  'kb/sec', $netRxPktTot/$intSecs);
      sendData('nettotals.kbout',  'kb/sec', $netTxKBTot/$intSecs);
      sendData('nettotals.pktout', 'kb/sec', $netTxPktTot/$intSecs);
    }

    if ($gexSubsys=~/N/)
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
  }

  if ($gexSubsys=~/s/)
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

  if ($gexSubsys=~/t/)
  {
    sendData("tcpinfo.pureack", 'num/sec', $tcpValue[27]/$intSecs);
    sendData("tcpinfo.hpack",   'num/sec', $tcpValue[28]/$intSecs);
    sendData("tcpinfo.loss",    'num/sec', $tcpValue[40]/$intSecs);
    sendData("tcpinfo.ftrans",  'num/sec', $tcpValue[45]/$intSecs);
  }

  if ($gexSubsys=~/x/i)
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

  if ($gexSubsys=~/E/i)
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

  # if any imported data, it may want to include gexpr output.  However this means getting a list of
  # 3-tuples to call OUR formatting routines with so the import module doesn't have to.
  my (@names, @units, @vals);
  for (my $i=0; $i<$impNumMods; $i++) { &{$impPrintExport[$i]}('g', \@names, \@units, \@vals); }
  foreach (my $i=0; $i<scalar(@names); $i++)
  {
    sendData($names[$i], $units[$i], $vals[$i]);
  }
  $gexCounter=0    if $gexCounter==$gexSendCount;
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

# this code tightly synchronized with lexpr
sub sendData
{
  my $name=shift;
  my $units=shift;
  my $value=shift;

  # We have to increment at the top since multiple exit points (shame on me) so the
  # very first entry starts at 1 rather than 0;
  $gexDataIndex++;
  $value=int($value);

  # These are only undefined the very first time
  if (!defined($gexTTL[$gexDataIndex]))
  {
    $gexTTL[$gexDataIndex]=$gexTTL;
    $gexDataLast[$gexDataIndex]=-1;
  }

  # As a minor optimization, only do this when dealing with min/max/avg values
  if ($gexFlags)
  {
    # And while this should be done in init(), we really don't know how may indexes
    # there are until our first pass through...
    if ($gexCounter==1)
    {
      $gexDataMin[$gexDataIndex]=$gexOneTB;
      $gexDataMax[$gexDataIndex]=0;
      $gexDataTot[$gexDataIndex]=0;
    }

    $gexDataMin[$gexDataIndex]=$value    if $gexMinFlag && $value<$gexDataMin[$gexDataIndex];
    $gexDataMax[$gexDataIndex]=$value    if $gexMaxFlag && $value>$gexDataMax[$gexDataIndex];
    $gexDataTot[$gexDataIndex]+=$value   if $gexAvgFlag;
  }

  return('')    if $gexCounter!=$gexSendCount;

  #    A c t u a l    S e n d    H a p p e n s    H e r e

  # If doing min/max/avg, reset $value
  if ($gexFlags)
  {
    $value=$gexDataMin[$gexDataIndex]    if $gexMinFlag;
    $value=$gexDataMax[$gexDataIndex]    if $gexMaxFlag;
    $value=($gexDataTot[$gexDataIndex]/$gexSendCount)    if $gexAvgFlag;
  }

  # Always send send data if not CO mode,but if so only send when it has
  # indeed changed OR TTL about to expire
  my $valSentFlag=0;
  if (!$gexCOFlag || $value!=$gexDataLast[$gexDataIndex] || $gexTTL[$gexDataIndex]==1)
  {
    $valSentFlag=1;
    sendMetaPacket($name, $units);
    sendDataPacket($name, $value);    
    $gexDataLast[$gexDataIndex]=$value;
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
    printf "$timestamp Name: %-25s Units: %-12s Val: %8d TTL: %d %s\n",
                $name, $units, $value, $gexTTL[$gexDataIndex], ($valSentFlag) ? 'sent' : ''
                        if $gexDebug & 1 || $valSentFlag;
  }

  # TTL only applies when in 'CO' mode, noting we already made expiration
  # decision above when we saw counter of 1
  if ($gexCOFlag)
  {
    $gexTTL[$gexDataIndex]--          if !$valSentFlag;
    $gexTTL[$gexDataIndex]=$gexTTL    if $valSentFlag || $gexTTL[$gexDataIndex]==0;
  }
}

sub sendMetaPacket
{
  my $name= shift;
  my $units=shift;

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

  $string.=pack('N', 3);         # slope
  $string.=pack('N', 2*$gexTTL*$gexInterval);   # time to live
  $string.=pack('N', 0);         # dmax
  $string.=pack('N', 0);

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

1;
