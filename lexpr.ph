# Call with --custom "lexpr[,[filename][,subsys]]"
#   note: filename does not include directory, default=L
#         if subsys is specified these are the subsytems reported on NOT all
#            the ones listed with -s
my ($filename, $filespec, $lexopts);
sub lexprInit
{
  $filename=shift;
  $lexopts= shift;

  $filename='L'    if !defined($filename) || $filename eq '';
  $filespec="$expDir/$filename";

  $lexopts=$subsys    if !defined($lexopts);
  error("options to lexpr not a proper subset of '$subsys'")    if $lexopts!~/^[$subsys]+$/;
}

sub lexpr
{
  my $sumFlag=$subsys=~/[cdfilmnstxE]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/         ? 1 : 0;

  my ($cpuSumString,$cpuDetString)=('','');
  if ($lexopts=~/c/i)
  {
    if ($lexopts=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;
      $cpuSumString.=sprintf("cputotals.user %d\n",  $userP[$i]);
      $cpuSumString.=sprintf("cputotals.nice %d\n",  $niceP[$i]);
      $cpuSumString.=sprintf("cputotals.sys %d\n",   $sysP[$i]);
      $cpuSumString.=sprintf("cputotals.wait %d\n",  $waitP[$i]);
      $cpuSumString.=sprintf("cputotals.irq %d\n",   $irqP[$i]);
      $cpuSumString.=sprintf("cputotals.soft %d\n",  $softP[$i]);
      $cpuSumString.=sprintf("cputotals.steal %d\n", $stealP[$i]);
      $cpuSumString.=sprintf("cputotals.idle %d\n",  $idleP[$i]);

      $cpuSumString.=sprintf("ctxint.ctx %d\n",  $ctxt/$intSecs);
      $cpuSumString.=sprintf("ctxint.int %d\n",  $intrpt/$intSecs);
      $cpuSumString.=sprintf("ctxint.proc %d\n", $proc/$intSecs);
      $cpuSumString.=sprintf("ctxint.runq %d\n", $loadQue);
    }

    if ($lexopts=~/C/)
    {
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $cpuDetString.=sprintf("cpuinfo.user.cpu$i %d\n",   $userP[$i]);
        $cpuDetString.=sprintf("cpuinfo.nice.cpu$i %d\n",   $niceP[$i]);
        $cpuDetString.=sprintf("cpuinfo.sys.cpu$i %d\n",    $sysP[$i]);
        $cpuDetString.=sprintf("cpuinfo.wait.cpu$i %d\n",   $waitP[$i]);
        $cpuDetString.=sprintf("cpuinfo.irq.cpu$i %d\n",    $irqP[$i]);
        $cpuDetString.=sprintf("cpuinfo.soft.cpu$i %d\n",   $softP[$i]);
        $cpuDetString.=sprintf("cpuinfo.steal.cpu$i %d\n",  $stealP[$i]);
        $cpuDetString.=sprintf("cpuinfo.idle.cpu$i %d\n",   $idleP[$i]);
        $cpuDetString.=sprintf("cpuinfo.intrpt.cpu$i %d\n", $intrptTot[$i]);
      }
    }
  }

  my ($diskSumString,$diskDetString)=('','');
  if ($lexopts=~/d/i)
  {
    if ($lexopts=~/d/)
    {
      $diskSumString.=sprintf("disktotals.reads %d\n",    $dskReadTot/$intSecs);
      $diskSumString.=sprintf("disktotals.readkbs %d\n",  $dskReadKBTot/$intSecs);
      $diskSumString.=sprintf("disktotals.writes %d\n",   $dskWriteTot/$intSecs);
      $diskSumString.=sprintf("disktotals.writekbs %d\n", $dskWriteKBTot/$intSecs);
    }

    if ($lexopts=~/D/)
    {
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $diskDetString.=sprintf("diskinfo.reads.$dskName[$i] %d\n",    $dskRead[$i]/$intSecs);
        $diskDetString.=sprintf("diskinfo.readkbs.$dskName[$i] %d\n",  $dskReadKB[$i]/$intSecs);
        $diskDetString.=sprintf("diskinfo.writes.$dskName[$i] %d\n",   $dskWrite[$i]/$intSecs);
        $diskDetString.=sprintf("diskinfo.writekbs.$dskName[$i] %d\n", $dskWriteKB[$i]/$intSecs);
      }
    }
  }

  my $nfsString='';
  if ($lexopts=~/f/)
  {
    $nfsString.=sprintf("nfsinfo.read %d\n",  $nfsRead/$intSecs);
    $nfsString.=sprintf("nfsinfo.write %d\n", $nfsWrite/$intSecs);
    $nfsString.=sprintf("nfsinfo.calls %d\n", $rpcCalls/$intSecs);
  }

  my $inodeString='';
  if ($lexopts=~/i/)
  {
    $inodeString.="inodeinfo.unuseddcache $unusedDCache\n";
    $inodeString.="inodeinfo.openfiles $openFiles\n";
    $inodeString.="inodeinfo.inodeused $inodeUsed\n";
    $inodeString.="inodeinfo.superused $superUsed\n";
    $inodeString.="inodeinfo.dquotused $dquotUsed\n";
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($lexopts=~/l/)
  {
    if ($CltFlag)
    {
      $lusSumString.=sprintf("lusclt.reads %d\n",    $lustreCltReadTot/$intSecs);
      $lusSumString.=sprintf("lusclt.readkbs %d\n",  $lustreCltReadKBTot/$intSecs);
      $lusSumString.=sprintf("lusclt.writes %d\n",   $lustreCltWriteTot/$intSecs);
      $lusSumString.=sprintf("lusclt.writekbs %d\n", $lustreCltWriteKBTot/$intSecs);
      $lusSumString.=sprintf("lusclt.numfs %d\n",    $NumLustreFS);
    }

    if ($MdsFlag)
    {
      $lusSumString.=sprintf("lusclt.close %d\n",    $lustreMdsClose/$intSecs);
      $lusSumString.=sprintf("lusclt.getattr %d\n",  $lustreMdsGetattr/$intSecs);
      $lusSumString.=sprintf("lusclt.reint %d\n",    $lustreMdsReint/$intSecs);
      $lusSumString.=sprintf("lusclt.sync %d\n",     $lustreMdsSync/$intSecs);
    }

    if ($OstFlag)
    {
      $lusSumString.=sprintf("lusost.reads %d\n",    $lustreReadOpsTot/$intSecs);
      $lusSumString.=sprintf("lusost.readkbs %d\n",  $lustreReadKBytesTot/$intSecs);
      $lusSumString.=sprintf("lusost.writes %d\n",   $lustreWriteOpsTot/$intSecs);
      $lusSumString.=sprintf("lusost.writekbs %d\n", $lustreWriteKBytesTot/$intSecs);
    }

  }

  my $memString='';
  if ($lexopts=~/m/)
  {
    $memString.="meminfo.tot $memTot\n";
    $memString.="meminfo.used $memUsed\n";
    $memString.="meminfo.free $memFree\n";
    $memString.="meminfo.shared $memShared\n";
    $memString.="meminfo.buf $memBuf\n";
    $memString.="meminfo.cached $memCached\n";
    $memString.="meminfo.slab $memSlab\n";
    $memString.="meminfo.map $memMap\n";
    $memString.="swapinfo.total $swapTotal\n";
    $memString.="swapinfo.used $swapUsed\n";
  }

  my ($netSumString,$netDetString)=('','');
  if ($lexopts=~/n/i)
  {
    if ($lexopts=~/n/)
    {
      $netSumString.=sprintf("nettotals.kbin %d\n",   $netRxKBTot/$intSecs);
      $netSumString.=sprintf("nettotals.pktin %d\n",  $netRxPktTot/$intSecs);
      $netSumString.=sprintf("nettotals.kbout %d\n",  $netTxKBTot/$intSecs);
      $netSumString.=sprintf("nettotals.pktout %d\n", $netTxPktTot/$intSecs);
    }

    if ($lexopts=~/N/)
    {
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;
        $netDetString.=sprintf("netinfo.kbin.$netName[$i] %d\n",   $netRxKB[$i]/$intSecs);
        $netDetString.=sprintf("netinfo.pktin.$netName[$i] %d\n",  $netRxPkt[$i]/$intSecs);
        $netDetString.=sprintf("netinfo.kbout.$netName[$i] %d\n",  $netTxKB[$i]/$intSecs);
        $netDetString.=sprintf("netinfo.pktout.$netName[$i] %d\n", $netTxPkt[$i]/$intSecs);
      }
    }
  }

  my $sockString='';
  if ($lexopts=~/s/)
  {
    $sockString.="sockinfo.used $sockUsed\n";
    $sockString.="sockinfo.tcp $sockTcp\n";
    $sockString.="sockinfo.orphan $sockOrphan\n";
    $sockString.="sockinfo.tw $sockTw\n";
    $sockString.="sockinfo.alloc $sockAlloc\n";
    $sockString.="sockinfo.mem $sockMem\n";
    $sockString.="sockinfo.udp $sockUdp\n";
    $sockString.="sockinfo.raw $sockRaw\n";
    $sockString.="sockinfo.frag $sockFrag\n";
    $sockString.="sockinfo.fragm $sockFragM\n";
  }

  my $tcpString='';
  if ($lexopts=~/t/)
  {
    $tcpString.=sprintf("tcpinfo.pureack %d\n", $tcpValue[27]/$intSecs);
    $tcpString.=sprintf("tcpinfo.hypack %d\n", $tcpValue[28]/$intSecs);
    $tcpString.=sprintf("tcpinfo.loss %d\n", $tcpValue[40]/$intSecs);
    $tcpString.=sprintf("tcpinfo.ftrans %d\n", $tcpValue[45]/$intSecs);
  }

  my $intString='';
  if ($lexopts=~/x/i)
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
   
    $intString.=sprintf("iconnect.kbin %d\n",   $kbInT/$intSecs);
    $intString.=sprintf("iconnect.pktin %d\n",  $pktInT/$intSecs);
    $intString.=sprintf("iconnect.kbout %d\n",  $kbOutT/$intSecs);
    $intString.=sprintf("iconnect.pktout %d\n", $pktOutT/$intSecs);
  }

  my $envString='';
  if ($lexopts=~/E/i)
  {
    foreach $key (sort keys %$ipmiData)
    {
      for (my $i=0; $i<scalar(@{$ipmiData->{$key}}); $i++)
      {
        my $name=$ipmiData->{$key}->[$i]->{name};
        my $inst=($key!~/power/ && $ipmiData->{$key}->[$i]->{inst} ne '-1') ? $ipmiData->{$key}->[$i]->{inst} : '';
        $envString.="env.$name$inst $ipmiData->{$key}->[$i]->{value}\n";
      }
    }
  }

  my $lexprRec='';
  $lexprRec.="sample.time $lastSecs\n"    if $sumFlag;
  $lexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $lexprRec.="$lusSumString$sockString$tcpString$intString$envString";

  $lexprRec.="sample.time $lastSecs\n"   if !$sumFlag;
  $lexprRec.="$cpuDetString$diskDetString$netDetString";

  # Either send data over socket or print to terminal OR write to
  # a file, but not both!
  if ($sockFlag || $expDir eq '')
  {
    printText($lexprRec, 1);    # include EOL marker at end
  }
  elsif ($expDir ne '')
  {
    open  EXP, ">$filespec" or logmsg("F", "Couldn't create '$filespec'");
    print EXP  $lexprRec;
    close EXP;
  }
}
1;
