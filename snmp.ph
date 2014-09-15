# copyright, 2003-2009 Hewlett-Packard Development Company, LP

# NOTE - everyting in absolute value NOT /sec except:
#    o=i  InReceives, InDelivers, OutRequests
#    o=t  ActiveOpens, PassiveOpens, OutSegs, InSegs
#    o=u  InDatagrame, OutDatagrams

# Allow reference to collectl variables, but be CAREFUL as these should be treated as readonly
our ($miniFiller, $rate, $SEP, $datetime, $intSecs, $showColFlag, $verboseFlag);

use strict;

# Global to this module
my $intervalCounter=0;
my $options='';
my (%snmp, $ipErrors, $icmpErrors, $tcpErrors, $udpErrors);
my ($tcpLossTOT, $tcpRetransTOT, $ipErrorsTOT, $icmpErrorsTOT, $tcpErrorsTOT, $udpErrorsTOT);

sub snmpInit
{
  my $impOptsref=shift;
  my $impKeyref= shift;

  # Options are 'icmtu', standing for Ip, Icmp, IcmpMsg, Tcp and Udp
  my $opts=$$impOptsref;
  $options='i'    if $verboseFlag;    # we need to set it to something!
  if (defined($opts))
  {
    foreach my $option (split(/,/,$opts))
    {
      my ($name, $value)=split(/=/, $option);
      error("invalid snmp option: '$name'")    if $name !~/[ho]/;
      error("o= values must be a combination of 'cimtuIT'")    if $name eq 'o' && $value!~/^[cimtuIT]+$/;
      $options=$value;
      $verboseFlag=1;    # forces --verbose
    }
  }
  snmphelp()         if defined($$impOptsref) && $$impOptsref=~/h/;
  error('IcmpMsg not being recorded')    if $options=~/m/ && `cat /proc/net/snmp`!~/IcmpMsg/;

  # These may not always be available in all releases
  $snmp{TcpExt}->{TW}=$snmp{TcpExt}->{PAWSEstab}=$snmp{TcpExt}->{DelayedACKs}=0;
  $snmp{TcpExt}->{DelayedACKLost}=$snmp{TcpExt}->{TCPPrequeued}=$snmp{TcpExt}->{TCPDirectCopyFromPrequeue}=0;
  $snmp{TcpExt}->{TCPHPHits}=$snmp{TcpExt}->{TCPPureAcks}=$snmp{TcpExt}->{TCPHPAcks}=0;
  $snmp{TcpExt}->{TCPDSACKOldSent}=$snmp{TcpExt}->{TCPAbortOnData}=$snmp{TcpExt}->{TCPAbortOnClose}=0;
  $snmp{TcpExt}->{TCPSackShiftFallback}=0;

  $snmp{IpExt}->{InMcastPkts}=$snmp{IpExt}->{InBcastPkts}=$snmp{IpExt}->{InOctets}=0;
  $snmp{IpExt}->{InMcastOctets}=$snmp{IpExt}->{InBcastOctets}=$snmp{IpExt}->{OutMcastPkts}=0;
  $snmp{IpExt}->{OutOctets}=$snmp{IpExt}->{OutMcastOctets}=0;

  # NOTE - there is no detail data, just summary
  $$impOptsref='s';
  $$impKeyref='snmp';
  return(1);
}

# nothing to add to collectl's header
sub snmpUpdateHeader
{
}

sub snmpGetData
{
  getProc(0, '/proc/net/snmp', 'snmp');
  getProc(0, '/proc/net/netstat', 'snmp');
}

sub snmpInitInterval
{
  $intervalCounter++;
}

sub snmpAnalyze
{
  my $type=   shift;
  my $dataref=shift;

  # the first value will be a header or data
  my ($snmpType, $val1)=(split(/\s+/, $$dataref))[0,1];
  $snmpType=~s/:$//;
  if ($val1=~/^\d/)
  {
    my @vals=split(/\s+/, $$dataref);
    for (my $i=1; $i<@vals; $i++)
    {
      # remember, first value is the type so we skipped it, but use index of 0
      my $name=$snmp{$snmpType}->{hdr}->[$i-1];
      my $value=$vals[$i]-$snmp{$snmpType}->{last}->[$i-1];
      #print "Type: $snmpType  Name: $name  I: $i  Val: $vals[$i]\n";

      $snmp{$snmpType}->{$name}=$value;
      $snmp{$snmpType}->{last}->[$i-1]=$vals[$i];
    }
  }

  # Only on the very first interval do we pull out the header names so we 
  # can use them when referencing specific counters during print
  elsif ($intervalCounter==1)
  {
    my @headers=split(/\s+/, $$dataref);
    for (my $i=1; $i<@headers; $i++)
    {
      $snmp{$snmpType}->{last}->[$i-1]=0;
      $snmp{$snmpType}->{hdr}->[$i-1]=$headers[$i];
    }
  }
}

sub snmpPrintBrief
{
  my $type=shift;
  my $lineref=shift;

  if ($type==1)       # header line 1
  {
    $$lineref.="<-------Tcp/Ip Errors-------->";
  }
  elsif ($type==2)    # header line 2
  {
    $$lineref.=" Loss FTrn   Ip Icmp  Tcp  Udp ";
  }
  elsif ($type==3)    # data
  {
    $ipErrors=     $snmp{Ip}->{InHdrErrors}+$snmp{Ip}->{InAddrErrors}+$snmp{Ip}->{InUnknownProtos}+
                   $snmp{Ip}->{InDiscards}+$snmp{Ip}->{OutDiscards}+$snmp{Ip}->{ReasmFails}+$snmp{Ip}->{FragFails};
    $icmpErrors=   $snmp{Icmp}->{InErrors}+$snmp{Icmp}->{InDestUnreachs}+$snmp{Icmp}->{OutErrors};
    $tcpErrors=    $snmp{Tcp}->{AttemptFails}+$snmp{Tcp}->{InErrs};
    $udpErrors=    $snmp{Udp}->{NoPorts}+$snmp{Udp}->{InErrors};
    $$lineref.=sprintf(" %4d %4d %4d %4d %4d %4d ",
		$snmp{TcpExt}->{TCPLoss}, $snmp{TcpExt}->{TCPFastRetrans},
		$ipErrors, $icmpErrors, $tcpErrors, $udpErrors);
  }
  elsif ($type==4)    # reset 'total' counters
  { 
    $tcpLossTOT=$tcpRetransTOT=$ipErrorsTOT=$icmpErrorsTOT=$tcpErrorsTOT=$udpErrorsTOT=0;
  }
  elsif ($type==5)    # increment 'total' counters
  {
    $tcpLossTOT+=   $snmp{TcpExt}->{TCPLoss};
    $tcpRetransTOT+=$snmp{TcpExt}->{TCPFastRetrans};
    $ipErrorsTOT+=  $ipErrors;
    $icmpErrorsTOT+=$icmpErrors;
    $tcpErrorsTOT+= $tcpErrors;
    $udpErrorsTOT+= $udpErrors;
  }
  elsif ($type==6)    # print 'total' counters
  {
    printf " %4d %4d %4d %4d %4d %4d ",
		$tcpLossTOT, $tcpRetransTOT, $ipErrorsTOT, $icmpErrorsTOT, $tcpErrorsTOT, $udpErrorsTOT;
  }

}

sub snmpPrintVerbose
{
  my $printHeader=shift;
  my $homeFlag=   shift;
  my $lineref=    shift;

  my $line='';
  $$lineref='';
  if ($printHeader)
  {
    # we've got the room so let's use an extra column for each and have the same
    # headers for 'R' and because I'm lazy.
    $line.="\n"    if !$homeFlag;
    $line.="# SNMP SUMMARY\n";
    $line.="#$miniFiller";
    $line.="<----------------------------------IpPkts----------------------------------->"    if $options=~/i/;
    $line.="<----------------------------Icmp--------------------------->"                    if $options=~/c/;
    $line.="<---------------------------------Tcp--------------------------------->"          if $options=~/t/;
    $line.="<------------Udp----------->"                                                     if $options=~/u/;

    # pain in the butt, but the types of messages in the header are variable
    my $tempHeader='----IcmpMsg---';
    if ($options=~/m/)
    {
      my $numFields=0;
      foreach my $type (sort keys %{$snmp{IcmpMsg}})
      { $numFields++; }    # note it includes hrd/last too

      for (my $i=0; $i<$numFields-4; $i++)
      { $tempHeader="----$tempHeader----"; }

      $line.="<$tempHeader>";
    }

    $line.="<------------------------------------------TcpExt----------------------------------------->"   if $options=~/T/;
    $line.="<-------------------------IpExt------------------------>"                                      if $options=~/I/;
    $line.="\n";

    $line.="#$miniFiller";
    $line.=" Receiv Delivr Forwrd DiscdI InvAdd   Sent DiscrO ReasRq ReasOK FragOK FragCr"    if $options=~/i/;
    $line.=" Recvd FailI UnreI EchoI ReplI  Trans FailO UnreO EchoO ReplO"                    if $options=~/c/;
    $line.=" ActOpn PasOpn Failed ResetR  Estab   SegIn SegOut SegRtn SegBad SegRes"          if $options=~/t/;
    $line.="  InDgm OutDgm NoPort Errors"                                                     if $options=~/u/;

    if ($options=~/m/)
    {
      foreach my $type (sort keys %{$snmp{IcmpMsg}})
      { 
        next    if $type=~/hdr|last/;

        # Keeping the total width to an even number makes it easier to build previous line.
	$type=~/(.{1}).*Type(\d+)/;   # first char I or O
        my $prefix=$1;
	my $number=$2;
	my $header=sprintf("Type%02d$prefix", $number);
        $line.=sprintf(" %7s", $header);
      }
    }

    $line.=" FasTim Reject DelAck QikAck PktQue PreQuB HdPdct AkNoPy PreAck DsAcks RUData REClos  SackS"   if $options=~/T/;
    $line.=" MPktsI BPktsI OctetI MOctsI BOctsI MPktsI OctetI MOctsI"   if $options=~/I/;
    $line.="\n";
  }
  $$lineref.=$line;
  return    if $showColFlag;

  $line='';
  $$lineref.=$line;

  $$lineref.="$datetime ";
  $$lineref.=sprintf(" %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d",
			$snmp{Ip}->{InReceives}/$intSecs,	$snmp{Ip}->{InDelivers}/$intSecs, 
			$snmp{Ip}->{ForwDatagrams}, 		$snmp{Ip}->{InDiscards}, 
			$snmp{Ip}->{InAddrErrors},  		$snmp{Ip}->{OutRequests}/$intSecs,
			$snmp{Ip}->{OutDiscards},   		$snmp{Ip}->{ReasmReqds},
			$snmp{Ip}->{ReasmOKs},      		$snmp{Ip}->{FragOKs},
			$snmp{Ip}->{FragCreates})
				if $options=~/i/; 

  $$lineref.=sprintf(" %5d %5d %5d %5d %5d  %5d %5d %5d %5d %5d",
			$snmp{Icmp}->{InMsgs},         $snmp{Icmp}->{InErrors},
			$snmp{Icmp}->{InDestUnreachs}, $snmp{Icmp}->{InEchos},
			$snmp{Icmp}->{InEchoReps},     $snmp{Icmp}->{OutMsgs},
			$snmp{Icmp}->{OutErrors},      $snmp{Icmp}->{OutDestUnreachs},
			$snmp{Icmp}->{OutEchos},       $snmp{Icmp}->{OutEchoReps})
				if $options=~/c/;

  # Looks like the contents of the icmpmsg data can vary from system to system...
  # Care WILL be needed with colmux!
  if ($options=~/m/)
  {
    foreach my $type (sort keys %{$snmp{IcmpMsg}})
    { 
      next    if $type=~/hdr|last/;
      $$lineref.=sprintf(" %7d", $snmp{IcmpMsg}->{$type});
    }
  }

  $$lineref.=sprintf(" %6d %6d %6d %6d %6d  %6d %6d %6d %6d %6d",
			$snmp{Tcp}->{ActiveOpens}/$intSecs,	$snmp{Tcp}->{PassiveOpens}/$intSecs,
			$snmp{Tcp}->{AttemptFails},		$snmp{Tcp}->{EstabResets},
			$snmp{Tcp}->{CurrEstab},		$snmp{Tcp}->{InSegs}/$intSecs, 
			$snmp{Tcp}->{OutSegs}/$intSecs,		$snmp{Tcp}->{RetransSegs},
			$snmp{Tcp}->{InErrs},       		$snmp{Tcp}->{OutRsts})
				if $options=~/t/;

  $$lineref.=sprintf(" %6d %6d %6d %6d",
			$snmp{Udp}->{InDatagrams}/$intSecs,	$snmp{Udp}->{OutDatagrams}/$intSecs,
			$snmp{Udp}->{NoPorts},      		$snmp{Udp}->{InErrors})
				if $options=~/u/;

  $$lineref.=sprintf(" %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d %6d",
			$snmp{TcpExt}->{TW},		 $snmp{TcpExt}->{PAWSEstab},
			$snmp{TcpExt}->{DelayedACKs},	 $snmp{TcpExt}->{DelayedACKLost},
			$snmp{TcpExt}->{TCPPrequeued},	 $snmp{TcpExt}->{TCPDirectCopyFromPrequeue},
			$snmp{TcpExt}->{TCPHPHits},	 $snmp{TcpExt}->{TCPPureAcks},
			$snmp{TcpExt}->{TCPHPAcks}, 	 $snmp{TcpExt}->{TCPDSACKOldSent},
			$snmp{TcpExt}->{TCPAbortOnData}, $snmp{TcpExt}->{TCPAbortOnClose},
			$snmp{TcpExt}->{TCPSackShiftFallback})
				if $options=~/T/;

  $$lineref.=sprintf(" %6d %6d %6d %6d %6d %6d %6d %6d",
			$snmp{IpExt}->{InMcastPkts}, 	$snmp{IpExt}->{InBcastPkts},
			$snmp{IpExt}->{InOctets}, 	$snmp{IpExt}->{InMcastOctets},
			$snmp{IpExt}->{InBcastOctets}, 	$snmp{IpExt}->{OutMcastPkts},
			$snmp{IpExt}->{OutOctets}, 	$snmp{IpExt}->{OutMcastOctets})
				if $options=~/I/;
  $$lineref.="\n";
}	

sub snmpPrintPlot
{
  my $type=   shift;
  my $ref1=   shift;

  #    H e a d e r s

  if ($type==2)
  {
  }

  #    D a t a

  # Detail
  if ($type==4)
  {
  }
}

sub snmpPrintExport
{
  my $type=shift;
  my $ref1=shift;
  my $ref2=shift;
  my $ref3=shift;
  my $ref4=shift;

  if ($type=~/[gl]/)
  {
  }
  elsif ($type eq 's')
  {
  }
}

sub snmphelp
{
  my $help=<<SNMPEOF;

usage: snmp,o=[cimtuIT]

where options can be any combination of
  c - ICMP
  i - IP Pkts
  m - ICMP Msg
  t - TCP
  u - UDP
  I - Extended IP
  T - Extended TCP

SNMPEOF

  print $help;
  exit;
}
1;
