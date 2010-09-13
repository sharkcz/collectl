#####################################################
#    S - E x p r e s s i o n    S u p p o r t
#####################################################

my $sexprDispatch;
my $sexprHeaderPrinted;

sub sexpr
{
  sexprRaw()     if  $sexprDispatch==1;
  sexprRate()    if  $sexprDispatch==2;
}

sub sexprInit
{
  my $sexprType=shift;
  error("sexpr calling format is --export sexpr,[raw|rate]")
	if !defined($sexprType) || $sexprType!~/raw|rate/;

  error("--sexpr does not support -sJ")          if $subsys=~/J/;
  error("--sexpr with -sj also requires -sC")    if $subsys=~/j/ && $subsys!~/C/;

  $sexprHeaderPrinted=0;
  $sexprDispatch=($sexprType eq 'raw') ? 1 : 2;
}

sub sexprRaw
{
  sexprHeaderPrint()    if !$sexprHeaderPrinted;

  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  my $cpuSumString=$cpuDetString='';
  if ($subsys=~/c/i)
  {
    if ($subsys=~/c/)
    {
      my ($uTot, $nTot, $sTot, $iTot, $wTot, $irTot, $soTot, $stTot, $intTot)=(0,0,0,0,0,0,0,0);
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $uTot+=  $userLast[$i];
        $nTot+=  $niceLast[$i];
        $sTot+=  $sysLast[$i];
        $iTot+=  $idleLast[$i];
        $wTot+=  $waitLast[$i];
        $irTot+= $irqLast[$i];
        $soTot+= $softLast[$i];
        $stTot+= $stealLast[$i];
      }
      $cpuSumString.="$pad(cputotals (user $uTot) (nice $nTot) (sys $sTot) (idle $iTot) (wait $wTot) ";
      $cpuSumString.=               "(irq $irTot) (soft $soTot) (steal $stTot))\n";
      $cpuSumString.="$pad(ctxint (ctx $ctxtLast) (int $intrptLast) (proc $procLast) (runq $loadQue))\n";
    }

    if ($subsys=~/C/)
    {
      my ($name, $userTot, $niceTot, $sysTot, $idleTot, $waitTot, $irqTot, $softTot, $stealTot, $intTot)=
		('','','','','','','','','','');
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $name.=    "cpu$i ";
        $userTot.= "$userLast[$i] ";
        $niceTot.= "$userLast[$i] ";
        $sysTot.=  "$userLast[$i] ";
        $idleTot.= "$userLast[$i] ";
        $waitTot.= "$userLast[$i] ";
        $irqTot.=  "$irqLast[$i] ";
        $softTot.= "$softLast[$i] ";
        $stealTot.="$stealLast[$i] ";
        $intTot.=  "0 ";    # raw has no meaning since INTs totalled over all line entries
      }
      $name=~s/ $//;       $userTot=~s/ $//;    $niceTot=~s/ $//;
      $sysTot=~s/ $//;     $idleTot=~s/ $//;    $waitTot=~s/ $//;
      $irqTot=~s/ $//;     $softTot=~s/ $//;    $stealTot=~s/ $//;
      $irqTot=~s/ $//;

      $cpuDetString.="$pad(cpuinfo\n";
      $cpuDetString.="$pad  (name $name)\n";
      $cpuDetString.="$pad  (user $userTot)\n";
      $cpuDetString.="$pad  (nice $niceTot)\n";
      $cpuDetString.="$pad  (sys $sysTot)\n";
      $cpuDetString.="$pad  (idle $idleTot)\n";
      $cpuDetString.="$pad  (wait $waitTot))\n";
      $cpuDetString.="$pad  (irq $irqTot))\n";
      $cpuDetString.="$pad  (soft $softTot))\n";
      $cpuDetString.="$pad  (steal $stealTot))\n";
      $cpuDetString.="$pad  (int $intTot))\n";
    }
  }

  my $diskSumString=$diskDetString='';
  if ($subsys=~/d/i)
  {
    if ($subsys=~/d/)
    {
      my ($dRTot, $dRkbTot, $dWTot, $dWkbTot)=(0,0,0,0);
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dRTot+=   $dskFieldsLast[$i][0];
        $dRkbTot+= $dskFieldsLast[$i][2];
        $dWTot+=   $dskFieldsLast[$i][4];
        $dWkbTot+= $dskFieldsLast[$i][6];
      }
      $diskSumString.="$pad(disktotals (reads $dRTot) (readkbs $dRkbTot) (writes $dWTot) (writekbs $dWkbTot))\n";
    }

    if ($subsys=~/D/)
    {
      my ($dName, $dRTot, $dRkbTot, $dWTot, $dWkbTot)=('','','','','');
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dName.=   "$dskName[$i] ";
        $dRTot.=   "$dskFieldsLast[$i][0] ";
        $dRkbTot.= "$dskFieldsLast[$i][2] ";
        $dWTot.=   "$dskFieldsLast[$i][4] ";
        $dWkbTot.= "$dskFieldsLast[$i][6] ";
      }
      $dName=~s/ $//;
      $dRTot=~s/ $//;  $dRkbTot=~s/ $//;
      $dWTot=~s/ $//;  $dWkbTot=~s/ $//;
      $diskDetString.="$pad(diskinfo\n";
      $diskDetString.="$pad  (name $dName)\n";
      $diskDetString.="$pad  (reads $dRTot)\n";
      $diskDetString.="$pad  (readkbs $dRkbTot)\n";
      $diskDetString.="$pad  (writes $dWTot)\n";
      $diskDetString.="$pad  (writekbs $dWkbTot))\n";
    }
  }

  my $nfsString='';
  if ($subsys=~/f/)
  {
    $nfsString= "$pad(nfsinfo (read $nfsValuesLast[6]) (write $nfsValuesLast[7]) (calls $rpcCallsLast))\n";
  }

  my $inodeString='';
  if ($subsys=~/i/)
  {
    $inodeString= "$pad(inodeinfo (unuseddcache $unusedDCache) (openfiles $openFiles) ";
    $inodeString.="(inodeused $inodeUsed) (superused $superUsed)(dquotused $dquotUsed))\n";
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($subsys=~/l/)
  {
    if ($CltFlag)
    {
      my ($reads, $readKBs, $writes, $writeKBs)=(0,0,0,0);
      for (my $i=0; $i<$NumLustreFS; $i++)
      {
        $reads+=   $lustreCltReadLast[$i];
        $readKBs+= $lustreCltReadKBLast[$i];
        $writes+=  $lustreCltWriteLast[$i];
        $writeKBs+=$lustreCltWriteKBLast[$i];
      }
      $lusSumString.="$pad(lusclt (reads $reads) (readkbs $readKBs) (writes $writes) (writekbs $writeKBs) (numfs $NumLustreFS))\n";
    }

    if ($OstFlag)
    {
      my ($reads, $readKBs, $writes, $writeKBs)=(0,0,0,0);
      for (my $i=0; $i<$NumOst; $i++)
      {
        $reads+=   $lustreReadOpsLast[$i];
        $readKBs+= $lustreReadKBytesLast[$i];
        $writes+=  $lustreWriteOpsLast[$i];
        $writeKBs+=$lustreWriteKBytesLast[$i];
      }
      $lusSumString.="$pad(lusoss (reads $reads) (readkbs $readKBs) (writes $writes) (writekbs $writeKBs))\n";
    }

    if ($MdsFlag)
    {
      $lusSumString.="$pad(lusmds (close $lustreMdsCloseLast) (getattr $lustreMdsGetattrLast) ";
      $lusSumString.="(reint $lustreMdsReintLast) (sync $lustreMdsSyncLast))\n";
    }
  }

  my $memString='';
  if ($subsys=~/m/)
  {
    $memString= "$pad(meminfo (memtot $memTot) (memused $memUsed) (memfree $memFree) ";
    $memString.="(memshared $memShared) (membuf $memBuf) (memcached $memCached) ";
    $memString.="(memslab $memSlab) (memmap $memMap))\n";
  }

  my $netSumString=$netDetString='';
  if ($subsys=~/n/i)
  {
    if ($subsys=~/n/)
    {
      my ($kbinT, $pktinT, $kboutT, $pktoutT)=(0,0,0,0);
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName=~/lo|sit|bond/;  # also filters out 'ibbond'
        $kbinT+=  $netRxKBLast[$i];
        $pktinT+= $netRxPktLast[$i];
        $kboutT+= $netTxKBLast[$i];
        $pktoutT+=$netTxPktLast[$i];
      }
      $netSumString= "$pad(nettotals (netkbin $kbinT) (netpktin $pktinT) (netkbout $kboutT) (netpktout $pktoutT))\n";
    }

    if ($subsys=~/N/)
    {
      my ($name, $kbinT, $pktinT, $kboutT, $pktoutT)=('','','','','');
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;
        $name.=   "$netName[$i] ";
        $kbinT.=  "$netRxKBLast[$i] ";
        $pktinT.= "$netRxPktLast[$i] ";
        $kboutT.= "$netTxKBLast[$i] ";
        $pktoutT.="$netTxPktLast[$i] ";
      }
      $name=~s/ $|://g;    $kbinT=~s/ $//;    $pktinT=~s/ $//; 
      $kboutT=~s/ $//;     $pktoutT=~s/ $//;
      $netDetString= "$pad(netinfo\n";
      $netDetString.="$pad  (name $name)\n";
      $netDetString.="$pad  (netkbin $kbinT)\n";
      $netDetString.="$pad  (netpktin $pktinT)\n";
      $netDetString.="$pad  (netkbout $kboutT)\n";
      $netDetString.="$pad  (netpktout $pktoutT))\n";
    }
  }

  my $sockString='';
  if ($subsys=~/s/)
  {
    $sockString= "$pad(sockinfo (sockused $sockUsed) (socktcp $sockTcp) (sockorphan $sockOrphan) (socktw $sockTw) (sockalloc $sockAlloc) (sockmem $sockMem)";
    $sockString.="(sockudp $sockUdp) (sockraw $sockRaw) (sockfrag $sockFrag) (sockfragm $sockFragM))\n";
  }

  my $tcpString='';
  if ($subsys=~/t/)
  {
    $tcpString="$pad(tcpinfo (tcppureack $tcpLast[27]) (tcphpack $tcpLast[28]) (tcploss $tcpLast[40]) (tcpftrans $tcpLast[45]))\n";
  }

  my $intString='';
  if ($subsys=~/x/i)
  {
    my ($kbInT, $pktInT, $kbOutT, $pktOutT)=(0,0,0,0);
    for (my $i=0; $i<$NumXRails; $i++)
    {
      $kbInT+=  $elanRxMBLast[$i]*1024;
      $pktInT+= $elanRxLast[$i];
      $kbOutT+= $elanTxMBLast[$i]*1024;
      $pktOutT+=$elanTxLast[$i];
    }

    $port=$HCAPortActive;
    for (my $i=0; $i<$NumHCAs; $i++)
    {
      $kbInT+=  $ibFieldsLast[$i][$port][13];
      $pktInT+= $ibFieldsLast[$i][$port][15];
      $kbOutT+= $ibFieldsLast[$i][$port][12];
      $pktOutT+=$ibFieldsLast[$i][$port][14];
    }
    $intString="$pad(iconnect (intkbin $kbInT) (intpktin $pktInT) (intkbout $kbOutT) (intpktout $pktOutT))\n";
  }

  # Build up as a single string
  $sexprRec='';
  $sexprRec.="(collectl_summary\n"    if $XCFlag && $sumFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if $sumFlag;
  $sexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $sexprRec.="$lusSumString$sockString$tcpString$intString";
  $sexprRec.=")\n"                    if $XCFlag && $sumFlag;

  $sexprRec.="(collectl_detail\n"     if $XCFlag && $detFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if !$sumFlag;
  $sexprRec.="$cpuDetString$diskDetString$netDetString";
  $sexprRec.=")\n"                    if $XCFlag && $detFlag;

  # Either send data over socket or print to terminal OR write to
  # a file, but not both!
  if ($sockFlag || $expDir eq '')
  {
    printText($sexprRec, 1);    # include EOL marker at end
  }
  elsif ($expDir ne '')
  {
    open  SEXPR, ">$expDir/S" or logmsg("F", "Couldn't create '$expDir/S'");
    print SEXPR  $sexprRec;
    close SEXPR;
  }
}

sub sexprRate
{
  sexprHeaderPrint()    if !$sexprHeaderPrinted;

  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  my $cpuSumString=$cpuDetString='';
  if ($subsys=~/c/i)
  {
    if ($subsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;
      $cpuSumString.=sprintf("$pad(cputotals (user %d) (nice %d) (sys %d) (wait %d) (irq %d) (soft %d) (steal %d) (idle %d))\n",
		$userP[$i], $niceP[$i], $sysP[$i], $waitP[$i], $irqP[$i], $softP[$i], $stealP[$i], $idleP[$i]);
      $cpuSumString.=sprintf("$pad(ctxint (ctx %d) (int %d) (proc %d) (runq $loadQue))\n",
		$ctxt/$intSecs, $intrpt/$intSecs, $proc/$intSecs);
    }

    if ($subsys=~/C/)
    {
      my ($name, $userTot, $niceTot, $sysTot, $waitTot, $irqTot, $softT, $stealTot, $idleTot, $intTot)=
		('','','','','','','','','','');
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $name.=    "cpu$i ";
        $userTot.= "$userP[$i] ";
        $niceTot.= "$niceP[$i] ";
        $sysTot.=  "$sysP[$i] ";
        $waitTot.= "$waitP[$i] ";
	$irqTot.=  "$irqP[$i] ";
	$softTot.= "$softP[$i] ";
	$stealTot.="$stealP[$i] ";
        $idleTot.= "$idleP[$i] ";
        $intTot.=  "$intrptTot[$i] ";
      }
      $name=~s/ $//;       $userTot=~s/ $//;    $niceTot=~s/ $//;
      $sysTot=~s/ $//;     $waitTot=~s/ $//;    $irqTot=~s/ $//;
      $softTot=~s/ $//;    $stealTot=~s/ $//;   $idleTot=~s/ $//;
      $intTot=~s/ $//;

      $cpuDetString.="$pad(cpuinfo\n";
      $cpuDetString.="$pad  (name $name)\n";
      $cpuDetString.="$pad  (user $userTot)\n";
      $cpuDetString.="$pad  (nice $niceTot)\n";
      $cpuDetString.="$pad  (sys $sysTot)\n";
      $cpuDetString.="$pad  (wait $waitTot))\n";
      $cpuDetString.="$pad  (irq $irqTot)\n";
      $cpuDetString.="$pad  (soft $softTot)\n";
      $cpuDetString.="$pad  (steal $stealTot)\n";
      $cpuDetString.="$pad  (idle $idleTot)\n";
      $cpuDetString.="$pad  (int $intTot)\n";
    }
  }

  my $diskSumString=$diskDetString='';
  if ($subsys=~/d/i)
  {
    if ($subsys=~/d/)
    {
      $diskSumString.=sprintf("$pad(disktotals (reads %d) (readkbs %d) (writes %d) (writekbs %d))\n", 
		$dskReadTot/$intSecs,  $dskReadKBTot/$intSecs, 
		$dskWriteTot/$intSecs, $dskWriteKBTot/$intSecs);
    }

    if ($subsys=~/D/)
    {
      my ($dName, $dRTot, $dRkbTot, $dWTot, $dWkbTot)=('','','','','');
      for (my $i=0; $i<$NumDisks; $i++)
      {
        $dName.=   "$dskName[$i] ";
        $dRTot.=   sprintf("%d ", $dskRead[$i]/$intSecs);
        $dRkbTot.= sprintf("%d ", $dskReadKB[$i]/$intSecs);
        $dWTot.=   sprintf("%d ", $dskWrite[$i]/$intSecs);
        $dWkbTot.= sprintf("%d ", $dskWriteKB[$i]/$intSecs);
      }
      $dName=~s/ $//;
      $dRTot=~s/ $//;  $dRkbTot=~s/ $//;
      $dWTot=~s/ $//;  $dWkbTot=~s/ $//;
      $diskDetString.="$pad(diskinfo\n";
      $diskDetString.="$pad  (name $dName)\n";
      $diskDetString.="$pad  (reads $dRTot)\n";
      $diskDetString.="$pad  (readkbs $dRkbTot)\n";
      $diskDetString.="$pad  (writes $dWTot)\n";
      $diskDetString.="$pad  (writekbs $dWkbTot))\n";
    }
  }

  my $nfsString='';
  if ($subsys=~/f/)
  {
    $nfsString=sprintf("$pad(nfsinfo (read %d) (write %d) (calls %d))\n", 
	$nfsRead/$intSecs, $nfsWrite/$intSecs, $rpcCalls/$intSecs);
  }

  my $inodeString='';
  if ($subsys=~/i/)
  {
    $inodeString= "$pad(inodeinfo (unuseddcache $unusedDCache) (openfiles $openFiles) ";
    $inodeString.="(inodeused $inodeUsed) (superused $superUsed)(dquotused $dquotUsed))\n";
  }

  # No lustre details, at least not for now...
  my $lusSumString='';
  if ($subsys=~/l/)
  {
    if ($CltFlag)
    {
      $lusSumString.=sprintf("$pad(lusclt (reads %d) (readkbs %d) (writes %d) (writekbs %d) (numfs $NumLustreFS))\n",
            $lustreCltReadTot/$intSecs,      $lustreCltReadKBTot/$intSecs,
            $lustreCltWriteTot/$intSecs,     $lustreCltWriteKBTot/$intSecs);
    }

    if ($OstFlag)
    {
      $lusSumString.=sprintf("$pad(lusoss (reads %d) (readkbs %d) (writes %d) (writekbs %d))\n", 
		$lustreReadOpsTot/$intSecs,  $lustreReadKBytesTot/$intSecs, 
		$lustreWriteOpsTot/$intSecs, $lustreWriteKBytesTot/$intSecs);
    }

    if ($MdsFlag)
    {
      $lusSumString.=sprintf("$pad(lusmds (close %d) (getattr %d) (reint %d) (sync %d)\n", 
		$lustreMdsClose/$intSecs, $lustreMdsGetattr/$intSecs, 
		$lustreMdsReint/$intSecs, $lustreMdsSync/$intSecs);
    }
  }

  my $memString='';
  if ($subsys=~/m/)
  {
    $memString= "$pad(meminfo (memtot $memTot) (memused $memUsed) (memfree $memFree) ";
    $memString.="(memshared $memShared) (membuf $memBuf) (memcached $memCached) ";
    $memString.="(memslab $memSlab) (memmap $memMap))\n";
  }

  my $netSumString=$netDetString='';
  if ($subsys=~/n/i)
  {
    if ($subsys=~/n/)
    {
      $netSumString=sprintf("$pad(nettotals (netkbin %d) (netpktin %d) (netkbout %d) (netpktout %d))\n",
                $netRxKBTot/$intSecs, $netRxPktTot/$intSecs,
		$netTxKBTot/$intSecs, $netTxPktTot/$intSecs);
    }

    if ($subsys=~/N/)
    {
      my ($name, $kbinT, $pktinT, $kboutT, $pktoutT)=('', '','','','');
      for ($i=0; $i<$netIndex; $i++)
      {
        next    if $netName[$i]=~/lo|sit/;
        $name.=  "$netName[$i] ";
        $kbinT.=  sprintf("%d ", $netRxKB[$i]/$intSecs);
        $pktinT.= sprintf("%d ", $netRxPkt[$i]/$intSecs);
        $kboutT.= sprintf("%d ", $netTxKB[$i]/$intSecs);
        $pktoutT.=sprintf("%d ", $netTxPkt[$i]/$intSecs);
      }
      $name=~s/ $|://g;    $kbinT=~s/ $//;    $pktinT=~s/ $//; 
      $kboutT=~s/ $//;     $pktoutT=~s/ $//;
      $netDetString= "$pad(netinfo\n";
      $netDetString.="$pad  (name $name)\n";
      $netDetString.="$pad  (netkbin $kbinT)\n";
      $netDetString.="$pad  (netpktin $pktinT)\n";
      $netDetString.="$pad  (netkbout $kboutT)\n";
      $netDetString.="$pad  (netpktout $pktoutT))\n";
    }
  }

  my $sockString='';
  if ($subsys=~/s/)
  {
    $sockString= "$pad(sockinfo (sockused $sockUsed) (socktcp $sockTcp) (sockorphan $sockOrphan) (socktw $sockTw) (sockalloc $sockAlloc) (sockmem $sockMem)";
    $sockString.="(sockudp $sockUdp) (sockraw $sockRaw) (sockfrag $sockFrag) (sockfragm $sockFragM))\n";
  }

  my $tcpString='';
  if ($subsys=~/t/)
  {
    $tcpString=sprintf("$pad(tcpinfo (tcppureack %d) (tcphpack %d) (tcploss %d) (tcpftrans %d))\n",
	        $tcpValue[27]/$intSecs,  $tcpValue[28]/$intSecs,
        	$tcpValue[40]/$intSecs,  $tcpValue[45]/$intSecs);
  }

  my $intString='';
  if ($subsys=~/x/i)
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
    $intString=sprintf("$pad(iconnect (intkbin %d) (intpktin %d) (intkbout %d) (intpktout %d))\n", 
	$kbInT/$intSecs, $pktInT/$intSecs, $kbOutT/$intSecs, $pktOutT/$intSecs);
  }

  $sexprRec='';
  $sexprRec.="(collectl_summary\n"    if $XCFlag && $sumFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if $sumFlag;
  $sexprRec.="$cpuSumString$diskSumString$nfsString$inodeString$memString$netSumString";
  $sexprRec.="$lusSumString$sockString$tcpString$intString";
  $sexprRec.=")\n"                    if $XCFlag && $sumFlag;

  $sexprRec.="(collectl_detail\n"     if $XCFlag && $detFlag;
  $sexprRec.="$pad(sample (time $lastSecs))\n"    if !$sumFlag;
  $sexprRec.="$cpuDetString$diskDetString$netDetString";
  $sexprRec.=")\n"                    if $XCFlag && $detFlag;

  # Either send data over socket or print to terminal OR write to
  # a file, but not both!
  if ($sockFlag || $expDir eq '')
  {
    printText($sexprRec, 1);
  }
  elsif ($expDir ne '')
  {
    open  SEXPR, ">$expDir/S" or logmsg("F", "Couldn't create '$expDir/S'");
    print SEXPR  $sexprRec;
    close SEXPR;
  }
}

sub sexprHeaderPrint
{
  # 1 extra level of indent (looks prettier) for XC
  my $pad=$XCFlag ? '  ' : '';
  my $sumFlag=$subsys=~/[cdfilmnstx]/ ? 1 : 0;
  my $detFlag=$subsys=~/[CDN]/        ? 1 : 0;

  print "Create sexpr header file: $expDir/#\n"    if $debug & 8192;
  $sexprHeaderPrinted=1;

  $sexprHdr='';
  $sexprHdr.="(collect_summary\n"    if $XCFlag && $sumFlag;
  $sexprHdr.="$pad(sample (time var))\n";
  $sexprHdr.="$pad(cputotals (user val) (nice val) (sys val) (idle val) (wait val) (irq val) (soft val) (steal val))\n"
	if $subsys=~/c/;
  $sexprHdr.="$pad(ctxint (ctx val) (int val) (proc val) (runq val))\n"
	if $subsys=~/c/;
  $sexprHdr.="$pad(disktotals (reads val) (readkbs val) (writes val) (writekbs val))\n"
	if $subsys=~/d/;
  $sexprHdr.="$pad(nfsinfo (read val) (write val) (calls val))\n"
        if $subsys=~/f/;
  $sexprHdr.="$pad(inodeinfo (unuseddcache val) (openfiles val) (inodeused val) (superuer val)(dquotused val))\n"
	if $subsys=~/i/;
  $sexprHdr.="$pad(lusclt (reads val) (readkbs val) (writes val) (writekbs val) (numfs val))\n"
	if $subsys=~/l/ && $CltFlag;
  $sexprHdr.="$pad(lusmds (close val) (getattr val) (reint val) (sync val))\n"
	if $subsys=~/l/ && $MdsFlag;
  $sexprHdr.="$pad(lusoss (reads val) (readkbs val) (writes val) (writekbs val))\n"
	if $subsys=~/l/ && $OstFlag;
  $sexprHdr.="$pad(meminfo (memtot val) (memused val) (memfree val) (memshared val) (membuf val) (memcached val) (memslab val) (memmap val))\n"
        if $subsys=~/m/;
  $sexprHdr.="$pad(nettotals (netkbin val) (netpktin val) (netkbout val) (netpktout val))\n"
        if $subsys=~/n/;
  $sexprHdr.="$pad(sockinfo (sockused val) (socktcp val) (sockorphan val) (socktw val) (sockalloc val) (sockmem val)(sockudp val) (sockraw val) (sockfrag val) (sockfragm val))\n"
        if $subsys=~/s/;
  $sexprHdr.="$pad(tcpinfo (tcppureack val) (tcphpack val) (tcploss val) (tcpftrans val))\n"
        if $subsys=~/t/;
  $sexprHdr.="$pad(iconnect (intkbin val) (intpktin val) (intkbout val) (intpktout val))\n"
        if $subsys=~/x/;
  $sexprHdr.=")\n"    if $XCFlag && $sumFlag;

  $sexprHdr.="(collect_detail \n"    if $XCFlag && $subsys=~/[CDN]/;
  if ($subsys=~/C/)
  {
    my $names='';
    $sexprHdr.="$pad(cpuinfo\n";
    for (my $i=0; $i<$NumCpus; $i++)
    {
      $names.="cpu$i ";
    }
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (user $names)\n";
    $sexprHdr.="$pad  (nice $names)\n";
    $sexprHdr.="$pad  (sys $names)\n";
    $sexprHdr.="$pad  (idle $names)\n";
    $sexprHdr.="$pad  (wait $names)\n";
    $sexprHdr.="$pad  (irq $names)\n";
    $sexprHdr.="$pad  (soft $names)\n";
    $sexprHdr.="$pad  (steal $names)\n";
    $sexprHdr.="$pad  (int $names)\n";
  }

  if ($subsys=~/D/)
  {
    my $names='';
    $sexprHdr.="$pad(diskinfo\n";
    for (my $i=0; $i<$NumDisks; $i++)
    {
      $names.="$dskName[$i] ";
    }
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (reads $names)\n";
    $sexprHdr.="$pad  (readkbs $names)\n";
    $sexprHdr.="$pad  (writes $names)\n";
    $sexprHdr.="$pad  (writekbs $names)\n";
  }

  if ($subsys=~/N/)
  {
    my $names='';
    $sexprHdr.="$pad(netinfo\n";
    for (my $i=0; $i<$NumNets; $i++)
    {
      next    if $netName[$i]=~/lo|sit/;
      $names.="$netName[$i] ";
    }
    $names=~s/://g;
    $sexprHdr.="$pad  (name $names)\n";
    $sexprHdr.="$pad  (netkbin $names)\n";
    $sexprHdr.="$pad  (netpktin $names)\n";
    $sexprHdr.="$pad  (netkbout $names)\n";
    $sexprHdr.="$pad  (netpktout $names)\n";
  }
  $sexprHdr.=")\n"    if $detFlag && $XCFlag;

  # The header only goes to a file
  if ($expDir ne '')
  {
    open  SEXPR, ">$expDir/#" or logmsg("F", "Couldn't create '$expDir/#'");
    print SEXPR  $sexprRec;
    close SEXPR;
  }
}
1;
