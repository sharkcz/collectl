# copyright, 2003-2009 Hewlett-Packard Development Company, LP

# Call with --custom "lexpr[,switches]
# Debug
#   1 - show all names/values
#   2 - just show names/values 'sent'
#   4 - unsed
#   8 - do not send anything 
#       (useful when displaying normal output on terminal)

my ($lexSubsys, $lexInterval, $lexDebug, $lexCOFlag, $lexTTL, $lexFilename, $lexSumFlag);
my ($lexDataIndex, @lexDataLast, @lexDataMin, @lexDataMax, @lexDataTot, @lexTTL, $lexSendCount);
my ($lexMinFlag, $lexMaxFlag, $lexAvgFlag)=(0,0,0);
my $lexOneTB=1024*1024*1024*1024;
my $lexExtName='';
my $lexCounter=0;
my $lexFlags;
sub lexprInit
{
  # If we ever run with a ':' in the inteval, we need to be sure we're
  # only looking at the main one.
  my $lexInterval1=(split(/:/, $interval))[0];

  # Defaults for options
  $lexDebug=$lexCOFlag=0;
  $lexFilename='';
  $lexInterval=$lexInterval1;
  $lexSubsys=$subsys;
  $lexTTL=5;

  foreach my $option (@_)
  {
    my ($name, $value)=split(/=/, $option);
    error("invalid lexpr option '$name'")    if $name!~/^[dfisx]?$|^co$|^ttl$|^min$|^max$|^avg$/;

    $lexCOFlag=1           if $name eq 'co';
    $lexDebug=$value       if $name eq 'd';
    $lexFilename=$value    if $name eq 'f';
    $lexInterval=$value    if $name eq 'i';
    $lexSubsys=$value      if $name eq 's';
    $lexExtName=$value     if $name eq 'x';
    $lexTTL=$value         if $name eq 'ttl';
    $lexMinFlag=1          if $name eq 'min';
    $lexMaxFlag=1          if $name eq 'max';
    $lexAvgFlag=1          if $name eq 'avg';
  }

  # If importing data, and if not reporting anything else, $subsys will be ''
  $lexSumFlag=$lexSubsys=~/[cdfilmnstxE]/ ? 1 : 0;
  error("lexpr subsys options '$lexSubsys' not a proper subset of '$subsys'")
	    if $subsys ne '' && $lexSubsys!~/^[$subsys]+$/;

  error("lexpr cannot write a snapshot file and use a socket at the same time")
	if $sockFlag && $lexFilename ne '';

  # Using -f and f= will not result in raw or plot file so need this message.
  error ("using lexpr option 'f=' AND -f requires -P and/or --rawtoo")
	if $lexFilename ne '' && $filename ne '' && !$plotFlag && !$rawtooFlag;

  # if -f, use that dirname/L for snampshot file; otherwise use f= for it.
  $lexFilename=(-d $filename) ? "$filename/L" : dirname($filename)."/L"
	if $lexFilename eq '' && $filename ne '';

  # convert to the number of samples we want to send
  $lexSendCount=int($lexInterval/$lexInterval1);
  error("lexpr interval option not a multiple of '$lexInterval1' seconds")
        if $lexInterval1*$lexSendCount != $lexInterval;

  $lexFlags=$lexMinFlag+$lexMaxFlag+$lexAvgFlag;
  error("only 1 of 'min', 'max' or 'avg' with 'lexpr'")    if $lexFlags>1;
  error("'min', 'max' and 'avg' require lexpr 'i' that is > collectl's -i")
	if $lexFlags && $lexSendCount==1;

  if ($lexExtName ne '')
  {
    $lexExtBase=$lexExtName;
    $lexExtBase=~s/\..*//;    # in case extension
    $lexExtName.='.ph'    if $lexExtName!~/\./;

    my $tempName=$lexExtName;
    $lexExtName="$ReqDir/$lexExtName"    if !-e $lexExtName;
    if (!-e "$lexExtName")
    {
      my $temp="can't find lexpr extension file '$tempName' in ./";
      $temp.=" OR $ReqDir/"    if $ReqDir ne '.';
      error($temp);
    }
    require $lexExtName;
  }
}

sub lexpr
{
  # if not time to print and we're not doing min/max/tot, there's nothing to do.
  $lexCounter++;
  return    if ($lexCounter!=$lexSendCount && $lexFlags==0);

  # We ALWAYS process the same number of data elements for any collectl instance
  # so we can use a global index to point to the one we're currently using.
  $lexDataIndex=0;

  my ($cpuSumString,$cpuDetString)=('','');
  if ($lexSubsys=~/c/i)
  {
    if ($lexSubsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;
      $cpuSumString.=sendData("cputotals.user",  $userP[$i]);
      $cpuSumString.=sendData("cputotals.nice",  $niceP[$i]);
      $cpuSumString.=sendData("cputotals.sys",   $sysP[$i]);
      $cpuSumString.=sendData("cputotals.wait",  $waitP[$i]);
      $cpuSumString.=sendData("cputotals.irq",   $irqP[$i]);
      $cpuSumString.=sendData("cputotals.soft",  $softP[$i]);
      $cpuSumString.=sendData("cputotals.steal", $stealP[$i]);
      $cpuSumString.=sendData("cputotals.idle",  $idleP[$i]);

      # These 2 are redundant, but also handy
      $cpuSumString.=sendData("cputotals.systot",  $sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i]);
      $cpuSumString.=sendData("cputotals.usertot", $userP[$i]+$niceP[$i]);

      $cpuSumString.=sendData("ctxint.ctx",  $ctxt/$intSecs);
      $cpuSumString.=sendData("ctxint.int",  $intrpt/$intSecs);

      $cpuSumString.=sendData("proc.creates", $proc/$intSecs);
      $cpuSumString.=sendData("proc.runq",    $loadQue);
      $cpuSumString.=sendData("proc.run",     $loadRun);

      $cpuSumString.=sendData("cpuload.avg1",  $loadAvg1, '%4.2f');
      $cpuSumString.=sendData("cpuload.avg5",  $loadAvg5, '%4.2f');
      $cpuSumString.=sendData("cpuload.avg15", $loadAvg15,'%4.2f');
    }

    if ($lexSubsys=~/C/)
    {
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $cpuDetString.=sendData("cpuinfo.user.cpu$i",   $userP[$i]);
        $cpuDetString.=sendData("cpuinfo.nice.cpu$i",   $niceP[$i]);
        $cpuDetString.=sendData("cpuinfo.sys.cpu$i",    $sysP[$i]);
        $cpuDetString.=sendData("cpuinfo.wait.cpu$i",   $waitP[$i]);
        $cpuDetString.=sendData("cpuinfo.irq.cpu$i",    $irqP[$i]);
        $cpuDetString.=sendData("cpuinfo.soft.cpu$i",   $softP[$i]);
        $cpuDetString.=sendData("cpuinfo.steal.cpu$i",  $stealP[$i]);
        $cpuDetString.=sendData("cpuinfo.idle.cpu$i",   $idleP[$i]);
        $cpuDetString.=sendData("cpuinfo.intrpt.cpu$i", $intrptTot[$i]);

        $cpuSumString.=sendData("cputotals.systot.cpu$i",  $sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i]);
        $cpuSumString.=sendData("cputotals.usertot.cpu$i", $userP[$i]+$niceP[$i]);
      }
    }
  }

  my ($diskSumString,$diskDetString)=('','');
  if ($lexSubsys=~/d/i)
  {
    if ($lexSubsys=~/d/)
    {
      $diskSumString.=sendData("disktotals.reads",    $dskReadTot/$intSecs);
      $diskSumString.=sendData("disktotals.readkbs",  $dskReadKBTot/$intSecs);
      $diskSumString.=sendData("disktotals.writes",   $dskWriteTot/$intSecs);
      $diskSumString.=sendData("disktotals.writekbs", $dskWriteKBTot/$intSecs);
    }

    if ($lexSubsys=~/D/)
    {
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $diskDetString.=sendData("diskinfo.reads.$dskName[$i]",    $dskRead[$i]/$intSecs);
        $diskDetString.=sendData("diskinfo.readkbs.$dskName[$i]",  $dskReadKB[$i]/$intSecs);
        $diskDetString.=sendData("diskinfo.writes.$dskName[$i]",   $dskWrite[$i]/$intSecs);
        $diskDetString.=sendData("diskinfo.writekbs.$dskName[$i]", $dskWriteKB[$i]/$intSecs);
      }
    }
  }

  my $nfsString='';
  if ($lexSubsys=~/f/)
  {
    if ($nfsSFlag)
    {
      $nfsString.=sendData("nfsinfo.Sread",  $nfsSReadsTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Swrite", $nfsSWritesTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Smeta",  $nfsSMetaTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Scommit",$nfsSCommitTot/$intSecs);
    }
    if ($nfsCFlag)
    {
      $nfsString.=sendData("nfsinfo.Cread",  $nfsCReadsTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Cwrite", $nfsCWritesTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Cmeta",  $nfsCMetaTot/$intSecs);
      $nfsString.=sendData("nfsinfo.Ccommit",$nfsCCommitTot/$intSecs);
    }
  }

  my $inodeString='';
  if ($lexSubsys=~/i/)
  {
    $inodeString.=sendData("inodeinfo.dentrynum", $dentryNum);
    $inodeString.=sendData("inodeinfo.dentryunused", $dentryUnused);
    $inodeString.=sendData("inodeinfo.filesalloc", $filesAlloc);
    $inodeString.=sendData("inodeinfo.filesmax", $filesMax);
    $inodeString.=sendData("inodeinfo.inodeused", $inodeUsed);
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($lexSubsys=~/l/)
  {
    if ($CltFlag)
    {
      $lusSumString.=sendData("lusclt.reads",    $lustreCltReadTot/$intSecs);
      $lusSumString.=sendData("lusclt.readkbs",  $lustreCltReadKBTot/$intSecs);
      $lusSumString.=sendData("lusclt.writes",   $lustreCltWriteTot/$intSecs);
      $lusSumString.=sendData("lusclt.writekbs", $lustreCltWriteKBTot/$intSecs);
      $lusSumString.=sendData("lusclt.numfs",    $NumLustreFS);
    }

    if ($MdsFlag)
    {
      my $getattrPlus=$lustreMdsGetattr+$lustreMdsGetattrLock+$lustreMdsGetxattr;
      my $setattrPlus=$lustreMdsReintSetattr+$lustreMdsSetxattr;
      my $varName=($cfsVersion lt '1.6.5') ? 'reint' : 'unlink';
      my $varVal= ($cfsVersion lt '1.6.5') ? $lustreMdsReint : $lustreMdsReintUnlink;

      $lusSumString.=sendData('lusmds.gattrP',   $getattrPlus/$intSecs);
      $lusSumString.=sendData('lusmds.sattrP',   $setattrPlus/$intSecs);
      $lusSumString.=sendData('lusmds.sync',     $lustreMdsSync/$intSecs);
      $lusSumString.=sendData("lusmds.$varName", $varVal/$intSecs);
    }

    if ($OstFlag)
    {
      $lusSumString.=sendData("lusost.reads",    $lustreReadOpsTot/$intSecs);
      $lusSumString.=sendData("lusost.readkbs",  $lustreReadKBytesTot/$intSecs);
      $lusSumString.=sendData("lusost.writes",   $lustreWriteOpsTot/$intSecs);
      $lusSumString.=sendData("lusost.writekbs", $lustreWriteKBytesTot/$intSecs);
    }
  }

  my $memString='';
  if ($lexSubsys=~/m/)
  {
    $memString.=sendData("meminfo.tot", $memTot);
    $memString.=sendData("meminfo.used", $memUsed);
    $memString.=sendData("meminfo.free", $memFree);
    $memString.=sendData("meminfo.shared", $memShared);
    $memString.=sendData("meminfo.buf", $memBuf);
    $memString.=sendData("meminfo.cached", $memCached);
    $memString.=sendData("meminfo.slab", $memSlab);
    $memString.=sendData("meminfo.map", $memMap);
    $memString.=sendData("meminfo.inactive", $inactive);
    $memString.=sendData("meminfo.hugetot", $memHugeTot);
    $memString.=sendData("meminfo.hugefree", $memHugeFree);
    $memString.=sendData("meminfo.hugersvd", $memHugeRsvd);
    $memString.=sendData("meminfo.sunreclaim", $memSUnreclaim);
    $memString.=sendData("swapinfo.total", $swapTotal);
    $memString.=sendData("swapinfo.free", $swapFree);
    $memString.=sendData("swapinfo.used", $swapUsed);
    $memString.=sendData("swapinfo.in", $swapin/$intSecs);
    $memString.=sendData("swapinfo.out", $swapout/$intSecs);
    $memString.=sendData("pageinfo.fault", $pagefault/$intSecs);
    $memString.=sendData("pageinfo.majfault", $pagemajfault/$intSecs);
    $memString.=sendData("pageinfo.in", $pagein/$intSecs);
    $memString.=sendData("pageinfo.out", $pageout/$intSecs);
  }

  my ($netSumString,$netDetString)=('','');
  if ($lexSubsys=~/n/i)
  {
    if ($lexSubsys=~/n/)
    {
      $netSumString.=sendData("nettotals.kbin",   $netRxKBTot/$intSecs);
      $netSumString.=sendData("nettotals.pktin",  $netRxPktTot/$intSecs);
      $netSumString.=sendData("nettotals.kbout",  $netTxKBTot/$intSecs);
      $netSumString.=sendData("nettotals.pktout", $netTxPktTot/$intSecs);
    }

    if ($lexSubsys=~/N/)
    {
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;

        my $netName=$netName[$i];
        $netName=~s/:$//;
        $netDetString.=sendData("netinfo.kbin.$netName",   $netRxKB[$i]/$intSecs);
        $netDetString.=sendData("netinfo.pktin.$netName",  $netRxPkt[$i]/$intSecs);
        $netDetString.=sendData("netinfo.kbout.$netName",  $netTxKB[$i]/$intSecs);
        $netDetString.=sendData("netinfo.pktout.$netName", $netTxPkt[$i]/$intSecs);
      }
    }
  }

  my $sockString='';
  if ($lexSubsys=~/s/)
  {
    $sockString.=sendData("sockinfo.used", $sockUsed);
    $sockString.=sendData("sockinfo.tcp", $sockTcp);
    $sockString.=sendData("sockinfo.orphan", $sockOrphan);
    $sockString.=sendData("sockinfo.tw", $sockTw);
    $sockString.=sendData("sockinfo.alloc", $sockAlloc);
    $sockString.=sendData("sockinfo.mem", $sockMem);
    $sockString.=sendData("sockinfo.udp", $sockUdp);
    $sockString.=sendData("sockinfo.raw", $sockRaw);
    $sockString.=sendData("sockinfo.frag", $sockFrag);
    $sockString.=sendData("sockinfo.fragm", $sockFragM);
  }

  my $tcpString='';
  if ($lexSubsys=~/t/)
  {
    $tcpString.=sendData("tcpinfo.pureack", $tcpValue[27]/$intSecs);
    $tcpString.=sendData("tcpinfo.hypack", $tcpValue[28]/$intSecs);
    $tcpString.=sendData("tcpinfo.loss", $tcpValue[40]/$intSecs);
    $tcpString.=sendData("tcpinfo.ftrans", $tcpValue[45]/$intSecs);
  }

  my $intString='';
  if ($lexSubsys=~/x/i)
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
   
    $intString.=sendData("iconnect.kbin",   $kbInT/$intSecs);
    $intString.=sendData("iconnect.pktin",  $pktInT/$intSecs);
    $intString.=sendData("iconnect.kbout",  $kbOutT/$intSecs);
    $intString.=sendData("iconnect.pktout", $pktOutT/$intSecs);
  }

  my $envString='';
  if ($lexSubsys=~/E/i)
  {
    foreach $key (sort keys %$ipmiData)
    {
      for (my $i=0; $i<scalar(@{$ipmiData->{$key}}); $i++)
      {
        my $name=$ipmiData->{$key}->[$i]->{name};
        my $inst=($key!~/power/ && $ipmiData->{$key}->[$i]->{inst} ne '-1') ? $ipmiData->{$key}->[$i]->{inst} : '';
        $envString.=sendData("env.$name$inst", $ipmiData->{$key}->[$i]->{value}, '%s');
      }
    }
  }

  # if any imported data, it may want to include lexpr output AND we do a little more work to
  # separate the summary from the detail
  my (@nameS, @valS, @nameD, @valD);
  my ($impSumString, $impDetString)=('','');
  for (my $i=0; $i<$impNumMods; $i++) { &{$impPrintExport[$i]}('l', \@nameS, \@valS, \@nameD, \@valD); }
  foreach (my $i=0; $i<scalar(@nameS); $i++) { $impSumString.=sendData($nameS[$i], $valS[$i]); }
  foreach (my $i=0; $i<scalar(@nameD); $i++) { $impDetString.=sendData($nameD[$i], $valD[$i]); }
  $lexSumFlag=1    if $impSumString ne '';   # in case not already set

  $lexprExtString='';
  &$lexExtBase(\$lexprExtString)    if $lexExtName ne '';

  # min/max/tot now updated, but there may be nothing to actally print yet
  return    if $lexCounter!=$lexSendCount;

  #     B u i l d    O u t p u t    S t r i n g

  my $lexprRec='';
  $lexprRec.="sample.time $lastSecs[$rawPFlag]\n"    if $lexSumFlag;
  $lexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $lexprRec.="$lusSumString$sockString$tcpString$intString$envString$impSumString";
  $lexprRec.=$lexprExtString;

  $lexprRec.="sample.time $lastSecs[$rawPFlag]\n"   if !$lexSumFlag;
  $lexprRec.="$cpuDetString$diskDetString$netDetString$impDetString";

  # Either send data over socket or print to terminal OR write to
  # a file, but not both!
  if ($sockFlag || $lexFilename eq '')
  {
    printText($lexprRec, 1);    # include EOL marker at end
  }
  elsif ($lexFilename ne '')
  {
    open  EXP, ">$lexFilename" or logmsg("F", "Couldn't create '$lexFilename'");
    print EXP  $lexprRec;
    close EXP;
  }
  $lexCounter=0;
}

# this code tightly synchronized with gexpr
sub sendData
{
  my $name= shift;
  my $value=shift;
  my $format=shift;

  # We have to increment at the top since multiple exit points (shame on me) so the
  # very first entry starts at 1 rather than 0;
  $lexDataIndex++;

  # These are only undefined the very first time
  if (!defined($lexTTL[$lexDataIndex]))
  {
    $lexTTL[$lexDataIndex]=$lexTTL;
    $lexDataLast[$lexDataIndex]=-1;
  }

  # As a minor optimization, only do this when dealing with min/max/avg values
  if ($lexFlags)
  {
    # And while this should be done in init(), we really don't know how may indexes
    # there are until our first pass through...
    if ($lexCounter==1)
    {
      $lexDataMin[$lexDataIndex]=$lexOneTB;
      $lexDataMax[$lexDataIndex]=0;
      $lexDataTot[$lexDataIndex]=0;
    }

    $lexDataMin[$lexDataIndex]=$value    if $lexMinFlag && $value<$lexDataMin[$lexDataIndex];
    $lexDataMax[$lexDataIndex]=$value    if $lexMaxFlag && $value>$lexDataMax[$lexDataIndex];
    $lexDataTot[$lexDataIndex]+=$value   if $lexAvgFlag;
  }
  return('')    if $lexCounter!=$lexSendCount;

  #    A c t u a l    S e n d    H a p p e n s    H e r e

  # If doing min/max/avg, reset $value
  if ($lexFlags)
  {
    $value=$lexDataMin[$lexDataIndex]    if $lexMinFlag;
    $value=$lexDataMax[$lexDataIndex]    if $lexMaxFlag;
    $value=($lexDataTot[$lexDataIndex]/$lexSendCount)    if $lexAvgFlag;
  }

  # Always send send data if not CO mode, but if so only send when it has
  # indeed changed OR TTL about to expire
  my $valSentFlag=0;
  my $returnString='';
  if (!$lexCOFlag || $value!=$lexDataLast[$lexDataIndex] || $lexTTL[$lexDataIndex]==1)
  {
    $valSentFlag=1;
    $format='%d'    if !defined($format);
    $returnString=sprintf("%s $format\n", $name, $value)    unless $lexDebug & 8;
    $lexDataLast[$lexDataIndex]=$value;
  }

  # A fair chunk of work, but worth it
  if ($lexDebug & 3)
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
    printf "$timestamp Name: %-20s Val: %8d TTL: %d %s\n",
		$name, $value, $lexTTL[$lexDataIndex], ($valSentFlag) ? 'sent' : ''
			if $lexDebug & 1 || $valSentFlag;
  }

  # TTL only applies when in 'CO' mode, noting we already made expiration
  # decision above when we saw counter of 1
  if ($lexCOFlag)
  {
    $lexTTL[$lexDataIndex]--          if !$valSentFlag;
    $lexTTL[$lexDataIndex]=$lexTTL    if $valSentFlag || $lexTTL[$lexDataIndex]==0;
  }
  return($returnString);
}

1;
