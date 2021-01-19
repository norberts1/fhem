###############################################################################
# $Id: 89_HEATRONIC.pm 10358 2016-01-04 14:53:12Z heikoranft $

###############################################################################
# This module is based on a work of Norbert S. described on
# http://www.mikrocontroller.net/topic/317004
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
###############################################################################



###############################################################################
#   Changelog:
#
#   2014-06-10  initial version
#   2014-06-10  wrong calculation of ch_Toutside
#   2014-06-11  wrong calculation of sol_Tcylinder_bottom
#   2014-06-11  logging telegram when error occurs
#   2014-06-12  new telegrams found: 9000ff0000d3020000a600 / 9000ff0000d3010000aa00
#   2014-06-12  documentation
#   2014-06-13  new telegrams with unknown length 9900ff00...
#   2014-06-14  disabled controller data with length 11 and 19
#   2014-06-15  error in handling controller data
#   2014-06-17  telegram length from 2014-06-13 determined: 9 Bytes, switching
#               heating mode (comfort, eco, frost) at specified time
#   2014-06-22  new: sub HEATRONIC_TimeDiff, interval_ch_time, 
#               interval_ch_Tflow_measured, interval_dhw_Tmeasured,
#               interval_dhw_Tcylinder, minDiff_ch_Tflow_measured
#   2014-06-29  logging messages 9000ff00
#   2014-07-03  found the reason for some weird controller data: the short message
#               with 9 Bytes accidentally has the correct CRC with length of 17 Bytes
#               -> fixed problem
#   2016-01-03  implemented patch created by Norbert S. junky-zs@gmx.de
#               (thanks to Norbert)
#               new function 'HEATRONIC_Set'
#               new intenal functions 'WriteHC_Trequested', 'WriteHC_mode' 
#               new: proxy server handling
#               fixed negative values of sol_Tcollector
#   2016-01-03  new: ch_code
#   2016-01-04  fixed bug in define
#   2016-05-14  added heating-circuit handling for controller type: CTxyz/CRxyz/CWxyz
#               added solar-message   handling for controller type: CTxyz/CRxyz/CWxyz
#               correted names in doc: hc1_Trequested and hc1_mode_requested
#   2019-01-07  Cxyz-controller handling added for RX and TX from/to heater-bus.
#               'ControllerName' attribute handling added.
#               new MsgID handling for: 26,30,615,797,798 and Powerswitch Modul.
#               Temperatur rangecheck modified for limit (0x7000) and value: -0.0.
#               added 'hcx_Tflow_desired' and 'hcx_pump'.
#               'sol_yield_last_hour' corrected, value now devided by 10.
#               example corrected 'eventMap' for 'attr Betriebsart.
#               Html-documentation updated, 'ch_Thdrylic_switch' added.
#   2021-01-19  Reconnection after disconnection, 'sub HEATRONIC_Ready($)' added.
###############################################################################
#
#    Importend note:
#     This Release is NOT an official one and is only for testing-purposes.
#
#     If you have new test-results from your heater-system let us know.
#       junky-zs at gmx dot de
#
###############################################################################



# TODO:
# - $debug
# - $interval: time between messages in secs
# - ersetzen -> $hash->{buffer} .= unpack('H*',$buf)
# - Abfrage in der Form =~ "ff1002(.{4})(.*)1003(.{4})ff(.*)" ??
#   Problem: Erkennung anderer Längen


# list of abbreviations:
# ch  = central heating
# hc  = heating circuit
# dhw = domestic hot water
# sol = solar
# T   = temperatur

###############################################################################
#### examples for fhem.cfg and using heater-set functionality #################
###############################################################################
#
## Attribut for currently used heater-Controller
# attr <tag> ControllerName <name>
#  example: 
#   attr Heizung ControllerName FR120   # Fxyz-controllertype
#   or
#   attr Heizung ControllerName CW400   # Cxyz-controllertype
####
#############################################################
## define example for 'heating-mode' and Fxxy controller-type
#
# define Betriebsart dummy
# attr Betriebsart eventMap auto:auto heizen:comfort sparen:eco frost:frost
# attr Betriebsart room Heiz-System
# attr Betriebsart webCmd auto:comfort:eco:frost
# define notify_Betriebsart notify Betriebsart {\
#  my $modus=Value("Betriebsart");; \
#  {fhem("set Heizung hc1_mode_requested $modus")};; \
# }
#############################################################
## define example for 'heating-mode' and Cxxy controller-type
#
# define Betriebsart dummy
# attr Betriebsart eventMap auto:auto auto:comfort auto:eco auto:frost manual:manual
# attr Betriebsart room Heiz-System
# attr Betriebsart webCmd auto:manual
# define notify_Betriebsart notify Betriebsart {\
#  my $modus=Value("Betriebsart");; \
#  {fhem("set Heizung hc1_mode_requested $modus")};; \
# }
#############################################################
## define example for 'temperatur-niveau' and Fxxy or Cxyz controller-types
#
# define Heizen_Sollniveau dummy
# attr Heizen_Sollniveau setList state:slider,10,0.5,30,1
# attr Heizen_Sollniveau webCmd state
# attr Heizen_Sollniveau room Heiz-System
# define notify_Heizen_Sollniveau notify Heizen_Sollniveau {\
#  my $value=Value("Heizen_Sollniveau");; \
#  {fhem("set Heizung hc1_Trequested $value")};; \
# }
###############################################################################
#

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);
use IO::File;

sub HEATRONIC_Initialize($);
sub HEATRONIC_Define($$);
sub HEATRONIC_Undef($$);
#sub HEATRONIC_Attr(@);
sub HEATRONIC_Read($);
sub HEATRONIC_Ready($);
sub HEATRONIC_Set($@);
sub HEATRONIC_WriteHC_Trequested($$);
sub HEATRONIC_WriteHC_mode($$);
sub HEATRONIC_DecodeMsg_CH1($$$);
sub HEATRONIC_DecodeMsg_CH2($$$);
sub HEATRONIC_DecodeMsg_HC($$$);
sub HEATRONIC_DecodeMsg_DHW($$$);
sub HEATRONIC_DecodeMsg_REQ($$$);
sub HEATRONIC_DecodeMsg_DT($$$);
sub HEATRONIC_DecodeMsg_SOL($$$);
sub HEATRONIC_CRCtest($$$);
sub HEATRONIC_CRCget($);
sub HEATRONIC_timeDiff($);
sub HEATRONIC_msgID677($$$$);
sub HEATRONIC_msgPowerSwitchModul($$$$$);
sub HEATRONIC_msgID26($$$$);
sub HEATRONIC_msgID30($$$);
sub HEATRONIC_ControllerType($);

my @crc_table = qw( 0x00 0x02 0x04 0x06 0x08 0x0a 0x0c 0x0e 0x10 0x12 0x14 0x16 0x18 0x1a 0x1c 0x1e 
                    0x20 0x22 0x24 0x26 0x28 0x2a 0x2c 0x2e 0x30 0x32 0x34 0x36 0x38 0x3a 0x3c 0x3e
                    0x40 0x42 0x44 0x46 0x48 0x4a 0x4c 0x4e 0x50 0x52 0x54 0x56 0x58 0x5a 0x5c 0x5e
                    0x60 0x62 0x64 0x66 0x68 0x6a 0x6c 0x6e 0x70 0x72 0x74 0x76 0x78 0x7a 0x7c 0x7e
                    0x80 0x82 0x84 0x86 0x88 0x8a 0x8c 0x8e 0x90 0x92 0x94 0x96 0x98 0x9a 0x9c 0x9e
                    0xa0 0xa2 0xa4 0xa6 0xa8 0xaa 0xac 0xae 0xb0 0xb2 0xb4 0xb6 0xb8 0xba 0xbc 0xbe
                    0xc0 0xc2 0xc4 0xc6 0xc8 0xca 0xcc 0xce 0xd0 0xd2 0xd4 0xd6 0xd8 0xda 0xdc 0xde
                    0xe0 0xe2 0xe4 0xe6 0xe8 0xea 0xec 0xee 0xf0 0xf2 0xf4 0xf6 0xf8 0xfa 0xfc 0xfe
                    0x19 0x1b 0x1d 0x1f 0x11 0x13 0x15 0x17 0x09 0x0b 0x0d 0x0f 0x01 0x03 0x05 0x07
                    0x39 0x3b 0x3d 0x3f 0x31 0x33 0x35 0x37 0x29 0x2b 0x2d 0x2f 0x21 0x23 0x25 0x27
                    0x59 0x5b 0x5d 0x5f 0x51 0x53 0x55 0x57 0x49 0x4b 0x4d 0x4f 0x41 0x43 0x45 0x47
                    0x79 0x7b 0x7d 0x7f 0x71 0x73 0x75 0x77 0x69 0x6b 0x6d 0x6f 0x61 0x63 0x65 0x67
                    0x99 0x9b 0x9d 0x9f 0x91 0x93 0x95 0x97 0x89 0x8b 0x8d 0x8f 0x81 0x83 0x85 0x87
                    0xb9 0xbb 0xbd 0xbf 0xb1 0xb3 0xb5 0xb7 0xa9 0xab 0xad 0xaf 0xa1 0xa3 0xa5 0xa7
                    0xd9 0xdb 0xdd 0xdf 0xd1 0xd3 0xd5 0xd7 0xc9 0xcb 0xcd 0xcf 0xc1 0xc3 0xc5 0xc7
                    0xf9 0xfb 0xfd 0xff 0xf1 0xf3 0xf5 0xf7 0xe9 0xeb 0xed 0xef 0xe1 0xe3 0xe5 0xe7 );

my $buffer = "";
my $fh;
#my $debug;
my $interval_ch_time;

#define serial device (0) or proxy-server  (1)
my $PROXY_SERVER = 0;
 
# set telegramms and values
my %HEATRONIC_sets = (
  "hc1_mode_requested" => {OPT => ""}, # values are set in 'HEATRONIC_Initialize'
  "hc1_Trequested"     => {OPT => ":slider,10,0.5,30,1"}, # min 10, 0.5 celsius stepwith, max 30 celsius
);
 
my %HEATRONIC_set_mode_requested = (
  "manual"    => 0,
  "frost"     => 1,
  "eco"       => 2,
  "comfort"   => 3,
  "auto"      => 4
);

my %HEATRONIC_ControllerType_Value = (
  "F" => 1,
  "C" => 2
);

sub
HEATRONIC_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

  $hash->{DefFn}   = "HEATRONIC_Define";
  $hash->{UndefFn} = "HEATRONIC_Undef";
#  $hash->{AttrFn}  = "HEATRONIC_Attr";
  $hash->{ReadFn}  = "HEATRONIC_Read";
  $hash->{ReadyFn} = "HEATRONIC_Ready";
  $hash->{SetFn}   = "HEATRONIC_Set";
  $hash->{AttrList} =
    "do_not_notify:1,0 loglevel:0,1,2,3,4,5,6 " 
      ."log88001800:0,1 "
      ."log88003400:0,1 "
      ."log9000FF00:0,1 "
      ."interval_ch_time:0,60,300,600,900,1800,3600,7200,43200,86400 "
      ."interval_ch_Tflow_measured:0,15,30,60,300,600,900,1800,3600,7200,43200,86400 "
      ."interval_dhw_Tmeasured:0,15,30,60,300,600,900,1800,3600,7200,43200,86400 "
      ."interval_dhw_Tcylinder:0,15,30,60,300,600,900,1800,3600,7200,43200,86400 "
      ."minDiff_ch_Tflow_measured:0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0 "
      ."binary_operation:OR,AND "
      ."ControllerName:0,1 "
      . $readingFnAttributes;
  
  # set option-list
  my $optionList = join(",", sort keys %HEATRONIC_set_mode_requested);
  $HEATRONIC_sets{"hc1_mode_requested"}{OPT} = ":$optionList";
}


sub
HEATRONIC_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> HEATRONIC <devicename> or define <name> HEATRONIC <proxy-server IP-adr:port> ";
    Log3 $hash, 2, $msg;
    return $msg;
  }

  #Close Device to initialize properly
  if (index($a[2], ':') == -1) {
     delete $hash->{USBDev} if($hash->{USBDev});
     delete $hash->{FD};
  }
  else {
    ###proxy-server IP-adr and port found
    $PROXY_SERVER = 1;
  }
  DevIo_CloseDev($hash);

  my $name=$a[0];
  my $dev =$a[2];

  ###START###### Writing values to global hash ###############################################################START####
  $hash->{STATE} = "defined";

  $hash->{DeviceName} = $dev;
  
  $hash->{status}{FlagWritingSequence} = 0;

  $hash->{status}{HT_mode_requested} = 255; # default to auto mode used for Cxyz-controller
  ####END####### Writing values to global hash ################################################################END#####

  my $ret = DevIo_OpenDev($hash,0,"HEATRONIC_DoInit");
 # my $ret = DevIo_OpenDev($hash,0,0);
  
  $fh = IO::File->new("/opt/fhem/log/junkers.log",">");
  return $ret;
}



sub
HEATRONIC_Undef($$)
{
  my ( $hash, $arg ) = @_; 
  my $name = $hash->{NAME};  
  
  DevIo_CloseDev($hash);         
  RemoveInternalTimer($hash); 
  undef $fh;  
  return undef;              
}



sub
HEATRONIC_DoInit($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  if ($PROXY_SERVER == 1)
  {
    my $init = unpack('C/a', "\02RX");
    #Send 'RX'-client registration to proxy
    DevIo_SimpleWrite($hash, $init, 0);
  }
  $defs{$name}{STATE} = "initialized";

  return undef;
}

#sub
#HEATRONIC_Attr(@)
#{
#  my ($cmd, $name, $attrName, $attrVal) = @_;
  
#  my $hash = $defs{$name};
#  my $ret;
#}

sub
HEATRONIC_Read($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  my $x;
  my $value;
  my $length = 0;
  my $position = 0;

#  $debug = AttrVal($name, "debug", 0);
#  $interval_ch_time = AttrVal($name, "interval_ch_time", undef);



  ############################
  # read data

  my $buf = DevIo_SimpleRead($hash);
  return if (!defined($buf));
 
#  $fh->print($buf);
#  $fh->flush();
  
  $buffer .= unpack('H*',$buf);



  #############################
  # parse messages
  
  # request data
  if ($buffer =~ "88000700") 
  {
    $position = index($buffer,"88000700");
    $length = 21;  

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_REQ($hash,$buffer,$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
        $buffer = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'Request'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }

  
  # vessel data 
  elsif ($buffer =~ "88001800") 
  {
    $position = index($buffer,"88001800");
    # 7D
#    if (length(substr($buffer,$position)) >= 32);
#    if (substr())

    $length = 33; # length 31 or 33 Bytes

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_CH1($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        $length = 31;
        $value = HEATRONIC_DecodeMsg_CH1($hash,substr($buffer,$position,$length*2),$length);
        if (defined($value))
        {
          # nicht alles loeschen, da Laenge kleiner
          substr($buffer,$position,$length*2) = "";
        }
        else
        {
          Log3 $name, 3, "HEATRONIC error: Cannot handle message 'vessal data'";
          Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
          Log3 $name, 3, substr($buffer,$position,33*2) . HEATRONIC_CRCget(substr($buffer,$position,33*2));
          $buffer = "";
        }
      }
      else
      {
        $buffer = "";
      }
    }
  }
  

  # heating circuit data
  elsif ($buffer =~ "88001900")
  {
    $position = index($buffer,"88001900");
    $length = 33;

    if (length(substr($buffer,$position)) >= $length*2)
    {
      # Bsp: 88 00 19 00 00 d1 80 00 80 00 00 00 00 00 00 01 fc 00 06 44 00 00 00 00 04 e0 00 01 d4 80 00 a0 00
      $value = HEATRONIC_DecodeMsg_CH2($hash,substr($buffer,$position,$length*2),$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
        $buffer = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'heating circuit data'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }

  
  # domestic hot water data
  elsif ($buffer =~ "88003400")
  {
  
    $position = index($buffer,"88003400");
	
    # length 22, 23 or 25 Bytes
    $length = 25;
	
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_DHW($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        $length = 23;
        $value = HEATRONIC_DecodeMsg_DHW($hash,substr($buffer,$position,$length*2),$length);
        if (!defined($value))
        {
          $length = 22;
          $value = HEATRONIC_DecodeMsg_DHW($hash,substr($buffer,$position,$length*2),$length);
        }
      }
      
      if(defined($value))
      {
        # don't delete everything because of different lengths
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'domestic hot water data'";
        Log3 $name, 3, substr($buffer,$position,25*2) . HEATRONIC_CRCget(substr($buffer,$position,25*2));
        $buffer = "";
      }
    }
  }

  
  # date / time data
  elsif (($buffer =~ "90000600") or ($buffer =~ "98000600"))
  {
    my $foundstr = "90000600";
    if ($buffer =~ "98000600") {
      # send by CR/CW100 configured as controller
      $foundstr = "98000600";
    }
    $position = index($buffer,$foundstr);
    $length = 17; # length 14 or 17 Bytes <-- used with new controller-types: CTxyz/CRxyz/CWxyz
   
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_DT($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        $length = 14;
        $value = HEATRONIC_DecodeMsg_DT($hash,substr($buffer,$position,$length*2),$length);
      }

      if(defined($value))
      {
        # don't delete everything because of different lengths
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'date / time data'";
        Log3 $name, 3, substr($buffer,$position,17*2) . HEATRONIC_CRCget(substr($buffer,$position,17*2));
        $buffer = "";
      }
    }
  }

  ##################################
  ### message_ID: 467_0_0        ###
  ###  DHW system 1              ###
  ##################################
  elsif ($buffer =~ "9000ff0000d3")
  {
    $position = index($buffer,"9000ff0000d3");
    $length = 11;
    if (length(substr($buffer,$position)) >= $length*2)
    {
      # from 23:00 to 05:00 first value, second value otherwise
      # 9000ff0000d3020000a600
      # 9000ff0000d3010000aa00
      # SOTA-msg_ID-          where:SS:=SOurce; TT:=TArget;followed by msg_id
      #             02           := Automatik-Betrieb bei Kombigeraet ausgeschaltet
      #             01           := Automatik-Betrieb bei Kombigeraet eingeschaltet
      #             Funktion     : Betriebsart DHW 1
      #             Wertebereich := 0...9
      #               00         := Wert fuer Solare Unterstuetzung DHW1
      #                 00       := Status letzte termische Desinfection im DHW1
      #
      # This values currently not decoded and are unused
      $value = HEATRONIC_DecodeMsg_HC($hash,substr($buffer,$position,$length*2),$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'heating circuit data'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
  #######################################
  ### message_ID: 677_0_0             ###
  ###  RTSD hc1 or hc2                ###
  ###   Room temperatur setpoint data ###
  ###  (used by CTxyz/CRxyz/CWxyz)    ###
  #######################################
  elsif (($buffer =~ "9000ff0001a5") or ($buffer =~ "9800ff0001a5") or ($buffer =~ "9000ff0001a6") or ($buffer =~ "9800ff0001a6"))
  {
    my $foundstr = "9000ff0001a5";
    my $hc_circuit = 1;
    if ($buffer =~ "9800ff0001a5") 
    {
      $foundstr = "9800ff0001a5";
    } 
    elsif ($buffer =~ "9000ff0001a6") 
    {
      $foundstr = "9000ff0001a6";
      $hc_circuit = 2;
    } 
    elsif ($buffer =~ "9800ff0001a6") 
    {
      $foundstr = "9800ff0001a6";
      $hc_circuit = 2;
    }
    $position = index($buffer,$foundstr);
    $length = 33; # length 10,12,30,32 or 33 Bytes <-- used with new controller-types: CTxyz/CRxyz/CWxyz
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_msgID677($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
      if (!defined($value))
      {
        $length = 32;
        $value = HEATRONIC_msgID677($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
        if (!defined($value))
        {
          $length = 30;
          $value = HEATRONIC_msgID677($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
          if (!defined($value))
          {
            $length = 12;
            $value = HEATRONIC_msgID677($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
            if (!defined($value))
            {
                $length = 10;
                $value = HEATRONIC_msgID677($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
            }
          }
        }
      }
      if (defined($value))
      {
        # don't delete everything because of different lengths
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'controller data'";
        Log3 $name, 3, substr($buffer,$position,33*2) . HEATRONIC_CRCget(substr($buffer,$position,33*2));
        $buffer = "";
      }
    }
  }
  #######################################
  ### message_ID: 615 & 797,798   ###
  #######################################
  elsif (($buffer =~ "9000ff000167") or ($buffer =~ "9000ff00021d") or ($buffer =~ "9000ff00021e"))
  {
    my $foundstr = "";
    my $msgID=0;
    my $searchstr = "9000ff00";
       $length = 10;

    if ($buffer =~ ($searchstr."0167")) {
      # Floor dyring message
      $msgID=615;
      $foundstr = $searchstr."0167";
      $length = 10;
    }
    if ($buffer =~ ($searchstr."021d")) {
      # DHW1 extra message
      $msgID=797;
      $foundstr = $searchstr."021d";
      $length = 12;
    }
    if ($buffer =~ ($searchstr."021e")) {
      # DHW2 extra message
      $msgID=798;
      $foundstr = $searchstr."021e";
      $length = 12;
    }
    $position = index($buffer,$foundstr);
    if (length(substr($buffer,$position)) >= $length*2)
    {
      if ($msgID == 615) {
        # message unused, nothing to do
        $value = 1;
      }
      if ($msgID == 797) {
        # message not yet unused, nothing to do
        $value = 1;
      }
      if ($msgID == 798) {
        # message not yet unused, nothing to do
        $value = 1;
      }
      if (defined($value))
      {
        # don't delete everything because of different lengths
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'controller data'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
  ############################################
  ### message_ID: 26_0_0                   ###
  ### From Main-controller to heaterdevice ###
  ############################################
  elsif ($buffer =~ "90081a00")
  {
    my $foundstr = "90081a00";
    my $hc_circuit = 1;

    $position = index($buffer,$foundstr);
    $length = 9;  # length 9 or 7 Bytes
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_msgID26($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
      if (!defined($value))
      {
        $length = 7;
        $value = HEATRONIC_msgID26($hash,substr($buffer,$position,$length*2),$length,$hc_circuit);
      }
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message:".$foundstr;
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
  # controller data (Fxyz or Cxyz)
  elsif ($buffer =~ "9000ff00")
  {
    $position = index($buffer,"9000ff00");
    $length = 17;

    if (length(substr($buffer,$position)) >= $length*2)
    {
      my $logging = AttrVal($name, "log9000FF00", 0);
      
      $value = HEATRONIC_DecodeMsg_HC($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        # 2014-06-13 found new messages: 9000ff00006f02c4000, 9000ff00006f03c5000
        # at 22:00, 06:00

        $length = 9;
        $value = HEATRONIC_DecodeMsg_HC($hash,substr($buffer,$position,$length*2),$length);
      }
      
      if ($logging == 1)
      {
        my $fh_logging = IO::File->new("/opt/fhem/log/j9000FF00.log",">>");
        $fh_logging->print(strftime("%Y-%m-%d %H:%M:%S",localtime()) . ": " . substr($buffer,$position,$length*2) . "\n");
        $fh_logging->flush();
        undef $fh_logging;
      }
      
      if (defined($value))
      {
        # don't delete everything because of different lengths
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'controller data'";
        Log3 $name, 3, substr($buffer,$position,17*2) . HEATRONIC_CRCget(substr($buffer,$position,17*2));
        $buffer = "";
      }
    }
  }
  # Telegramm: Lastschaltmodul #1 or #2 (IPM/MM)
  elsif (($buffer =~ "a000ff00") or ($buffer =~ "a100ff00"))
  {
    my $foundstr = "";
    my $hc_circuit = 1;
    my $msgID=0;
    my $searchstr = "a000ff00";
    $length = 4;

    if ($buffer =~ $searchstr) {
      $hc_circuit = 1;
    } elsif ($buffer =~ "a100ff00") {
        $searchstr = "a100ff00";
        $hc_circuit = 2;
    }
    if ($buffer =~ ($searchstr."000c")) {
      # message_ID: 268_0_0
      $msgID=268;
      $foundstr = ($searchstr."000c");
      $length = 14;
    }
    if ($buffer =~ ($searchstr."0155")) {
      # message_ID: 597_0_0
      $msgID=597;
      $foundstr = ($searchstr."0155");
      $length = 9;
    }
    if ($buffer =~ ($searchstr."01d7")) {
      # message_ID: 727_0_0
      $msgID=727;
      $foundstr = ($searchstr."01d7");
      $length = 17;
    }
    if ($buffer =~ ($searchstr."01d8")) {
      # message_ID: 728_0_0
      $msgID=728;
      $foundstr = ($searchstr."01d8");
      $length = 17;
    }
    $position = index($buffer,$foundstr);
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_msgPowerSwitchModul($hash,substr($buffer,$position,$length*2),$length,$hc_circuit,$msgID);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      } else {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message:".$foundstr;
        Log3 $name, 3, substr($buffer,$position,17*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
  ##################################
  ### message_ID: 30_0_0         ###
  ### IPM/MM Msg to heaterdevice ###
  ###  hydraulic switch tempera  ###
  ##################################
  elsif (($buffer =~ "a0081e00") or ($buffer =~ "a1081e00"))
  {
    my $foundstr = "a0081e00";
    if ($buffer =~ "a1081e00") {
        $foundstr = "a1081e00";
    }
    $position = index($buffer,$foundstr);
    $length = 8;
    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_msgID30($hash,substr($buffer,$position,$length*2),$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      } else {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message:".$foundstr;
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
  ##################################  solar data (ISM1/2)  ###################
  ##################################
  ### message_ID: 259_0_0        ###
  ###  Solar message             ###
  ##################################
  elsif ($buffer =~ "b000ff000003")
  {
    $position = index($buffer,"b000ff000003");
    $length = 21;

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
        $buffer = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'solar data'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }

  ##################################
  ### message_ID: 260_0_0        ###
  ###  Solar message             ###
  ##################################
  elsif ($buffer =~ "b000ff000004")
  {
    $position = index($buffer,"b000ff000004");
    $length = 35;  # length 24 or 35 Bytes

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        $length = 24;
        $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      }

      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'solar data'";
        Log3 $name, 3, substr($buffer,$position,35*2) . HEATRONIC_CRCget(substr($buffer,$position,35*2));
        $buffer = "";
      }
    }
  }

  ##################################
  ### message_ID: 866_0_0        ###
  ###  Solar message             ###
  ###  controller: CT/CR/CWxyz   ###
  ##################################
  elsif ($buffer =~ "b000ff000262")
  {
    $position = index($buffer,"b000ff000262");
    $length = 32;  # length 10 or 32 Bytes

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      if (!defined($value))
      {
        $length = 10;
        $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      }

      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'solar data'";
        Log3 $name, 3, substr($buffer,$position,32*2) . HEATRONIC_CRCget(substr($buffer,$position,32*2));
        $buffer = "";
      }
    }
  }
  ##################################
  ### message_ID: 910_0_0        ###
  ###  Solar message             ###
  ###  controller: CT/CR/CWxyz   ###
  ##################################
  elsif ($buffer =~ "b000ff00028e")
  {
    $position = index($buffer,"b000ff00028e");
    $length = 20;

    if (length(substr($buffer,$position)) >= $length*2)
    {
      $value = HEATRONIC_DecodeMsg_SOL($hash,substr($buffer,$position,$length*2),$length);
      if (defined($value))
      {
        substr($buffer,$position,$length*2) = "";
      }
      else
      {
        Log3 $name, 3, "HEATRONIC error: Cannot handle message 'solar data'";
        Log3 $name, 3, substr($buffer,$position,$length*2) . HEATRONIC_CRCget(substr($buffer,$position,$length*2));
        $buffer = "";
      }
    }
  }
}

sub
HEATRONIC_Ready($)
{
  my ($hash) = @_;
 # try to reopen the connection in case the connection is lost
  return DevIo_OpenDev($hash, 1, "HEATRONIC_DoInit");
}

sub
HEATRONIC_Set($@)
{
  my ($hash, @a) = @_;
  my $name = $hash->{NAME};
  my $log_str="";
  my $call_rtn=0;
 
  return "\"set $name\" needs at least an argument" if(@a < 2);
 
  if(!defined($HEATRONIC_sets{$a[1]})) {
    my $msg = "";
    foreach my $para (sort keys %HEATRONIC_sets) {
      $msg .= " $para" . $HEATRONIC_sets{$para}{OPT};
    }
    return "Unknown argument $a[1], choose one of" . $msg;
  }

  my ($val, $numeric_val);

  # check available 'value' as parameter at first
  return "\"set $name $a[1]\" needs at least one parameter" if(@a < 2);

  $val = $a[2];
  $numeric_val = ($val =~ m/^[.0-9]+$/);

  if($a[1] =~ m/^hc.*Trequested$/) {
    $log_str = "Argument must be numeric (between 10 and 30)";

    # do error-handling if any
    Log3 ($name, 1, $log_str) if(!$numeric_val || $val < 10 || $val > 30);
    return $log_str if(!$numeric_val || $val < 10 || $val > 30);

    # execute command 
    $val *= 2;
    $call_rtn = HEATRONIC_WriteHC_Trequested($hash, $val);
    if ($call_rtn == 0) {
      # repeat one time if failed
      $call_rtn = HEATRONIC_WriteHC_Trequested($hash, $val);
    }
    # log command 
    $log_str = "HEATRONIC_WriteHC_Trequested".$a[2]." using value:".$val." success:".$call_rtn;
    Log3 ($name, 5, $log_str);
  }
  elsif($a[1] =~ m/_mode_requested/) {
    $val = $HEATRONIC_set_mode_requested{$val};
    $log_str = "Unknown parameter for $a[1], use one of ".join(" ", sort keys %HEATRONIC_set_mode_requested);

    # do error-handling if any
    Log3 ($name, 1, $log_str) if(!defined($val));
    return $log_str if(!defined($val));

    # execute command 
    $call_rtn = HEATRONIC_WriteHC_mode($hash, $val);
    if ($call_rtn == 0) {
      # repeat one time if failed
      $call_rtn = HEATRONIC_WriteHC_mode($hash, $val);
    }

    # log command 
    $log_str = "HEATRONIC_WriteHC_mode:".$a[2]." using value:".$val." success:".$call_rtn;
    Log3 ($name, 5, $log_str);
  }
  else {
    Log3 $name, 3, "HEATRONIC_Set error: Cannot handle parameter";
    return "HEATRONIC_Set error: Cannot handle parameter";
  }
}

sub
HEATRONIC_ControllerType($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $ControllerName = AttrVal($name, "ControllerName", 0);
  my $ControllerType = $HEATRONIC_ControllerType_Value{'F'};
  if ($ControllerName =~ "C") {
    $ControllerType = $HEATRONIC_ControllerType_Value{'C'};
  }
  # uncomment for test only #
  # Log3 $name, 3, "HEATRONIC_ControllerType:".$ControllerType;

  return $ControllerType;
}


sub
HEATRONIC_WriteHC_Trequested($$)
{
  my ($hash, $trequested) = @_;
  my $name = $hash->{NAME};
  my $block1 = "";
  my $block2 = "";

  if (!defined($hash)) {
    return undef;
  }

  # do not write if flag is set
  if ($hash->{status}{FlagWritingSequence} == 1) {
    return 0;
  }

  $hash->{status}{FlagWritingSequence} = 1;

  # Cmd's are a set of header + data
  # send bytes to 'ht_pitiny' | 'ht_piduino' (ht_transceiver)
  #   header=  '#',   <length>  ,'!' ,'S' ,0x11
  #   header= 0x23,(len(data)+3),0x21,0x53,0x11

  my $CType = HEATRONIC_ControllerType($hash);
  if ($CType == $HEATRONIC_ControllerType_Value{'C'}) {
    #### Command for Cxyz-controller-type ####
    ## send 1. bytes to target (10)hex := Main Controller
    #   data  = 0x10,0xff,offset,0x01,0xb9,tsoll
    #            offset :=  8 -> Automatic mode
    #            offset := 10 -> Manual    mode
    #   block = header+data
    my $msg_offset = 8; # offset for auto mode
    if ($hash->{status}{HT_mode_requested} == 0) {
      $msg_offset = 10; # offset for manual mode
    }

    $block1 = "230921531110FF".sprintf("%02x",$msg_offset)."01b9".sprintf("%02x",$trequested);
    DevIo_SimpleWrite($hash, $block1, 1);

    ## send 2. bytes to target (18)hex := Remote Controller
    #    this is forced, also if isn't any Remote Controller in system
    #   data  = 0x18,0xff,0x08,0x01,0xb9,tsoll
    #   block = header+data
    $block2 = "230921531118FF".sprintf("%02x",$msg_offset)."01b9".sprintf("%02x",$trequested);
    DevIo_SimpleWrite($hash, $block1, 1);
  } else 
  {
    #### Command for Fxyz-controller-type ####
    ## send 1. bytes to target (10)hex := Main Controller
    #   data  = 0x10,0xff,0x11,0x00,0x65,tsoll
    #   block = header+data
    $block1 = "230921531110FF110065" . sprintf("%02x",$trequested);
    DevIo_SimpleWrite($hash, $block1, 1);

    ## send 2. bytes to target (10)hex := Main Controller
    #   data  = 0x10,0xff,0x07,0x00,0x79,tsoll
    #   block = header+data
    $block2 = "230921531110FF070079" . sprintf("%02x",$trequested);
    DevIo_SimpleWrite($hash, $block2, 1);
  }
  # uncomment for debugging
  # Log3 $name, 3, "HEATRONIC_WriteHC_Trequested block1:".$block1;
  # Log3 $name, 3, "HEATRONIC_WriteHC_Trequested block2:".$block2;

  $hash->{status}{FlagWritingSequence} = 0;
  return 1;
}



sub
HEATRONIC_WriteHC_mode($$)
{
  my ($hash, $mode_requested) = @_;
  my $name = $hash->{NAME};

  if (!defined($hash)) {
    return undef;
  }

  # do not write if flag is set
  if ($hash->{status}{FlagWritingSequence} == 1) {
    return 0;
  }
  $hash->{status}{FlagWritingSequence} = 1;

  # Cmd's are a set of header + data
  #   header=  '#',   <length>  ,'!' ,'S' ,0x11
  #   header= 0x23,(len(data)+3),0x21,0x53,0x11

  my $CType = HEATRONIC_ControllerType($hash);
  if ($CType == $HEATRONIC_ControllerType_Value{'C'}) {
    #### Command for Cxyz-controller-type ####
    ## send 1. bytes to 'ht_pitiny' | 'ht_piduino' (ht_transceiver)
    #   data  = 0x10,0xff,0x00,0x01,0xb9,mode_requested
    #   block = header+data
    if ($mode_requested > 0) {
      # if not 'manual' = 0, then force it to 'auto'
      $mode_requested = 255;
    }
    my $block1 = "230921531110FF0001b9" . sprintf("%02x",$mode_requested);
    DevIo_SimpleWrite($hash, $block1, 1);

    $hash->{status}{HT_mode_requested} = $mode_requested;

    # uncomment for debugging
    # Log3 $name, 3, "HEATRONIC_WriteHC_mode block1:".$block1;
  } else 
  {
    #### Command for Fxyz-controller-type ####
    ## send 1. bytes to 'ht_pitiny' | 'ht_piduino' (ht_transceiver)
    #   data  = 0x10,0xff,0x0e,0x00,0x65,mode_requested
    #   block = header+data
    my $block1 = "230921531110FF0E0065" . sprintf("%02x",$mode_requested);
    DevIo_SimpleWrite($hash, $block1, 1);

    ## send 2. bytes to 'ht_pitiny' | 'ht_piduino' (ht_transceiver)
    #   data  = 0x10,0xff,0x04,0x00,0x79,mode_requested
    #   block=header+data
    my $block2 = "230921531110FF040079" . sprintf("%02x",$mode_requested);
    DevIo_SimpleWrite($hash, $block2, 1);

    $hash->{status}{HT_mode_requested} = $mode_requested;

    # uncomment for debugging
    # Log3 $name, 3, "HEATRONIC_WriteHC_mode block1:".$block1;
    # Log3 $name, 3, "HEATRONIC_WriteHC_mode block2:".$block2;
  }
  $hash->{status}{FlagWritingSequence} = 0;
  return 1;
}



sub
HEATRONIC_DecodeMsg_CH1($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};
  
  if (defined(HEATRONIC_CRCtest($hash,$string,$length)))
  {
    my $ch_Tflow_desired    = hex(substr($string,4*2,2));
    my $ch_Tflow_measured   = hex(substr($string,5*2,4))/10;
    my $ch_Treturn          = hex(substr($string,17*2,4))/10;
    my $ch_Tmixer           = hex(substr($string,13*2,4))/10;
    my $ch_burner_power     = hex(substr($string,8*2,2));
    my $ch_burner_operation = (hex(substr($string,9*2,2)) & 0x08) ? 1 : 0;
    my $ch_pump_heating     = (hex(substr($string,11*2,2)) & 0x20) ? 1 : 0;
    my $ch_pump_cylinder    = (hex(substr($string,11*2,2)) & 0x40) ? 1 : 0;
    my $ch_pump_circulation = (hex(substr($string,11*2,2)) & 0x80) ? 1 : 0;
    my $ch_burner_fan       = (hex(substr($string,11*2,2)) & 0x01) ? 1 : 0;
    my $ch_mode             = (hex(substr($string,9*2,2)) & 0x03);
    my $ch_code             = hex(substr($string,24*2,4));
    my $ch_22_num           = hex(substr($string,22*2,2));
    my $ch_23_num           = hex(substr($string,23*2,2));
    my $ch_22_char          = ($ch_22_num == 0) ? "0" : chr($ch_22_num);
    my $ch_23_char          = ($ch_23_num == 0) ? "0" : chr($ch_23_num);
    my $ch_error            = $ch_22_char . $ch_23_char;
	
	
    my $ch_Tflow_measuredTS     = ReadingsTimestamp( $name, "ch_Tflow_measured", undef );
    my $interval_ch_Tflow_measured = AttrVal($name, "interval_ch_Tflow_measured", -1);

    my $minDiff_ch_Tflow_measured = AttrVal($name, "minDiff_ch_Tflow_measured", 0);
    my $ch_Tflow_measuredOldVal = ReadingsVal( $name, "ch_Tflow_measured",0);

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "ch_Tflow_desired", $ch_Tflow_desired); 

    if (!defined($ch_Tflow_measuredTS))
    {
      $interval_ch_Tflow_measured = -1;
    }

    if ($interval_ch_Tflow_measured != 0 )
    {
      if (($interval_ch_Tflow_measured > 0) && (HEATRONIC_timeDiff($ch_Tflow_measuredTS) >= $interval_ch_Tflow_measured) || $interval_ch_Tflow_measured == -1)
      {
        if (abs($ch_Tflow_measuredOldVal-$ch_Tflow_measured) >= $minDiff_ch_Tflow_measured)
        {
          readingsBulkUpdate($hash, "ch_Tflow_measured", sprintf("%.1f",$ch_Tflow_measured)); 
        }
      }
    }

    readingsBulkUpdate($hash, "ch_Treturn", ($ch_Treturn*10 >= 0x7000) ? "-0.0" : sprintf("%.1f",$ch_Treturn));
    readingsBulkUpdate($hash, "ch_Tmixer", ($ch_Tmixer*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $ch_Tmixer));
    readingsBulkUpdate($hash, "ch_mode", $ch_mode);
    readingsBulkUpdate($hash, "ch_burner_fan", $ch_burner_fan);
    readingsBulkUpdate($hash, "ch_burner_operation", $ch_burner_operation);
    readingsBulkUpdate($hash, "ch_pump_heating", $ch_pump_heating);
    readingsBulkUpdate($hash, "ch_pump_cylinder", $ch_pump_cylinder);
    readingsBulkUpdate($hash, "ch_pump_circulation", $ch_pump_circulation);
    readingsBulkUpdate($hash, "ch_burner_power", $ch_burner_power);
    readingsBulkUpdate($hash, "ch_code", $ch_code);
    readingsBulkUpdate($hash, "ch_error", $ch_error);
    readingsEndUpdate($hash,1);

    return 1;
  }
  else
  {
    return undef;
  }
}



sub
HEATRONIC_DecodeMsg_CH2($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};

  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  {
    my $ch_Toutside = hex(substr($string,4*2,2));
    if ($ch_Toutside != 255) { $ch_Toutside = ($ch_Toutside * 256 + hex(substr($string,5*2,2))) / 10 }
    else {$ch_Toutside = (255 - hex(substr($string,5*2,2)))/-10;}

    my $ch_runtime_tot        = hex(substr($string,17*2,6));
    my $ch_runtime_ch         = hex(substr($string,23*2,6));
    my $ch_starts_tot         = hex(substr($string,14*2,6));
    my $ch_starts_ch          = hex(substr($string,26*2,6));
    my $ch_pump_heating_power = hex(substr($string,13*2,2));
	
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "ch_Toutside", sprintf("%.1f",$ch_Toutside));
    readingsBulkUpdate($hash, "ch_runtime_tot", $ch_runtime_tot);
    readingsBulkUpdate($hash, "ch_runtime_ch", $ch_runtime_ch);
    readingsBulkUpdate($hash, "ch_starts_tot", $ch_starts_tot);
    readingsBulkUpdate($hash, "ch_starts_ch", $ch_starts_ch);
    readingsBulkUpdate($hash, "ch_pump_heating_power", $ch_pump_heating_power);
    readingsEndUpdate($hash,1);

    return 1;
  }
  else 
  { 
    return undef;
  }
}

sub
HEATRONIC_msgPowerSwitchModul($$$$$)
{
  my ($hash,$string,$length,$circuit,$msgID) = @_;
  my $name = $hash->{NAME};
  my $hc_Tflow_desired;
  my $hc_Tflow_mixer;
  my $hc_mixer_position;
  my $hc_pump;

  my $prefix = "hc" . $circuit . "_";
  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  {
    readingsBeginUpdate($hash);
    # MsgID: 268 ##########################
    if ($msgID == 268) {
      if ($length >= 11)
      {
        $hc_Tflow_desired = hex(substr($string,11*2,2));
        readingsBulkUpdate($hash, $prefix . "Tflow_desired", $hc_Tflow_desired);
      }
      if ($length >= 9)
      {
        $hc_Tflow_mixer = (hex(substr($string,9*2,4)) / 10 );
        readingsBulkUpdate($hash, $prefix . "Tflow_mixer", ($hc_Tflow_mixer*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $hc_Tflow_mixer));
      }
      if ($length >= 8)
      {
        $hc_mixer_position = hex(substr($string,8*2,2));
        readingsBulkUpdate($hash, $prefix . "mixerposition", $hc_mixer_position);
      }
      if ($length >= 7)
      {
        # status heating-circuit (bit1(LSBit) - to bit8(MSBit))
        #  bit1 := status heating-circuit pump in this circuit
        #  bit2 := status relay for mixermotor
        #  bit3 := mixervalve closed
        $hc_pump = (hex(substr($string,7*2,2)) & 0x01) ? 1 : 0;
        readingsBulkUpdate($hash, $prefix . "pump", $hc_pump);
      }
    } # MsgID: 268 ##########################

    # MsgID: 597 ##########################
    if ($msgID == 597) {
      # still unknown message
    } # MsgID: 597 ##########################

    # MsgID: 727 or 728 ###################
    if (($msgID == 727) or ($msgID == 728)){
      if ($length >= 11)
      {
        $hc_Tflow_desired = hex(substr($string,11*2,2));
        readingsBulkUpdate($hash, $prefix . "Tflow_desired", $hc_Tflow_desired);
      }
      if ($length >= 9)
      {
        $hc_Tflow_mixer = (hex(substr($string,9*2,4)) / 10 );
        readingsBulkUpdate($hash, $prefix . "Tflow_mixer", ($hc_Tflow_mixer*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $hc_Tflow_mixer));
      }
      if ($length >= 8)
      {
        $hc_mixer_position = hex(substr($string,8*2,2));
        readingsBulkUpdate($hash, $prefix . "mixerposition", $hc_mixer_position);
      }
      if ($length >= 6)
      {
        $hc_pump = hex(substr($string,6*2,2));
        readingsBulkUpdate($hash, $prefix . "pump", $hc_pump);
      }
    } # MsgID: 727 or 728 ###################
    readingsEndUpdate($hash,1);
    return 1;
  }
  else 
  { 
    return undef;
  }
}

sub
HEATRONIC_msgID26($$$$)
{
  my ($hash,$string,$length,$circuit) = @_;
  my $name = $hash->{NAME};

  my $prefix = "hc" . $circuit . "_";
  my $hc_Tflow_desired;
  my $hc_pump = 0;
  
  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  { 
    readingsBeginUpdate($hash);
    if ($length >= 6)
    {
      $hc_Tflow_desired   = hex(substr($string,4*2,2));
      readingsBulkUpdate($hash, $prefix . "Tflow_desired", sprintf("%.1f",$hc_Tflow_desired));
    }
    if ($length >= 9)
    {
      $hc_pump   = hex(substr($string,5*2,2));
      $hc_pump  += hex(substr($string,6*2,2));
      if ($hc_pump > 0) {
        $hc_pump = 1;
      }
      readingsBulkUpdate($hash, $prefix . "pump", $hc_pump);
    }
    readingsEndUpdate($hash,1);
    return 1;
  }
  else 
  { 
    return undef;
  }
}

sub
HEATRONIC_msgID30($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};

  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  { 
    my $ch_Thdrylic_switch  = hex(substr($string,4*2,4))/10;
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "ch_Thdrylic_switch", ($ch_Thdrylic_switch*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $ch_Thdrylic_switch));
    readingsEndUpdate($hash,1);
    return 1;
  }
  else 
  { 
    return undef;
  }
}

sub
HEATRONIC_msgID677($$$$)
{
  my ($hash,$string,$length,$circuit) = @_;
  my $name = $hash->{NAME};

  my $prefix = "hc" . $circuit . "_";
  my $hc_Tdesired;
  my $hc_Tmeasured;
  my $hc_mode = 0;
  
  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  {
    readingsBeginUpdate($hash);
    if ($length >= 27)
    {
      $hc_mode = hex(substr($string,27*2,2));
      readingsBulkUpdate($hash, $prefix . "mode", $hc_mode);
    }
    if ($length >= 12)
    {
      $hc_Tdesired   = hex(substr($string,12*2,2))/2;
      readingsBulkUpdate($hash, $prefix . "Tdesired", sprintf("%.1f",$hc_Tdesired));
    }
    if ($length >= 10)
    {
      $hc_Tmeasured  = hex(substr($string,6*2,4))/10;
      readingsBulkUpdate($hash, $prefix . "Tmeasured", ($hc_Tmeasured*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $hc_Tmeasured));
    }
    readingsEndUpdate($hash,1);
    return 1;
  }
  else 
  { 
    return undef;
  }
}

sub
HEATRONIC_DecodeMsg_HC($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};

  my $type;
  my $prefix = "hc1_";
  my $hc_Tdesired;
  my $hc_Tmeasured;
  
  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  {

    # Messages of length 11 Bytes are unknown -> no handling
    if ($length == 11)
    { return 1; }
	
    $type = hex(substr($string,5*2,2));

    # heater circuid assigned values corrected: 14.05.2016
    if ($type == 111) { $prefix = "hc1_";}
    elsif($type == 112) { $prefix = "hc2_"; }
    elsif($type == 113) { $prefix = "hc3_"; }
    elsif($type == 114) { $prefix = "hc4_"; }
    elsif($type == 211) { return 1; }

    if ($length != 9)
    {
      $hc_Tdesired   = hex(substr($string,8*2,4))/10;
      $hc_Tmeasured  = hex(substr($string,10*2,4))/10;
    }
    my $hc_mode       = hex(substr($string,6*2,2));
	
    readingsBeginUpdate($hash);
    if ($length != 9)
    {
      readingsBulkUpdate($hash, $prefix . "Tdesired", sprintf("%.1f",$hc_Tdesired));
      readingsBulkUpdate($hash, $prefix . "Tmeasured", sprintf("%.1f",$hc_Tmeasured));
    }
    readingsBulkUpdate($hash, $prefix . "mode", $hc_mode);
    readingsEndUpdate($hash,1);

    return 1;
  }
  else 
  { 
    return undef;
  }
}



sub 
HEATRONIC_DecodeMsg_DHW($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};

  if (defined(HEATRONIC_CRCtest($hash,$string, $length)))
  {
    my $dhw_Tdesired  = hex(substr($string,4*2,2));
    my $dhw_Tmeasured = hex(substr($string,5*2,4))/10;
    my $dhw_Tcylinder = hex(substr($string,7*2,4))/10;
    my $ch_runtime_dhw = hex(substr($string,14*2,6));
    my $ch_starts_dhw = hex(substr($string,17*2,6));
    my $dhw_charge_once = (hex(substr($string,9*2,2)) & 0x02) ? 1 : 0;
    my $dhw_thermal_desinfection = (hex(substr($string,9*2,2)) & 0x04) ? 1 : 0;
    my $dhw_generating = (hex(substr($string,9*2,2)) & 0x08) ? 1 : 0;
    my $dhw_boost_charge = (hex(substr($string,9*2,2)) & 0x10) ? 1 : 0;
    my $dhw_Tok = (hex(substr($string,9*2,2)) & 0x20) ? 1 : 0;

   
    my $dhw_TmeasuredTS     = ReadingsTimestamp( $name, "dhw_Tmeasured", undef );
    my $interval_dhw_Tmeasured = AttrVal($name, "interval_dhw_Tmeasured", -1);

    my $dhw_TcylinderTS     = ReadingsTimestamp( $name, "dhw_Tcylinder", undef );
    my $interval_dhw_Tcylinder = AttrVal($name, "interval_dhw_Tcylinder",   -1);

	
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "dhw_Tdesired", $dhw_Tdesired);

    if (!defined($dhw_TmeasuredTS))
    {
      $interval_dhw_Tmeasured = -1;
    }

    if ($interval_dhw_Tmeasured != 0)
    {
      if (($interval_dhw_Tmeasured > 0) && (HEATRONIC_timeDiff($dhw_TmeasuredTS) >= $interval_dhw_Tmeasured) || $interval_dhw_Tmeasured == -1)
      {
        readingsBulkUpdate($hash, "dhw_Tmeasured", ($dhw_Tmeasured*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $dhw_Tmeasured));
      }
    }
    
    if (!defined($dhw_Tcylinder))
    {
      $interval_dhw_Tcylinder = -1;
    }

    if ($interval_dhw_Tcylinder != 0)
    {
      if (($interval_dhw_Tcylinder > 0) && (HEATRONIC_timeDiff($dhw_TcylinderTS) >= $interval_dhw_Tcylinder) || $interval_dhw_Tcylinder == -1)
      {
        readingsBulkUpdate($hash, "dhw_Tcylinder", ($dhw_Tcylinder*10 >= 0x7000) ? "-0.0" : sprintf("%.1f", $dhw_Tcylinder));
      }
    }
    
    readingsBulkUpdate($hash, "ch_runtime_dhw", $ch_runtime_dhw);
    readingsBulkUpdate($hash, "ch_starts_dhw", $ch_starts_dhw);
    readingsEndUpdate($hash,1);
    return 1;
  }
  else 
  { 
    return undef;
  }
}



sub
HEATRONIC_DecodeMsg_REQ($$$)
{
  my ($hash,$string,$length) = @_;
  return 1;
}



sub
HEATRONIC_DecodeMsg_DT($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};

  my $ch_timeTS = ReadingsTimestamp( $name, "ch_time", undef );
  my $interval_ch_time = AttrVal($name, "interval_ch_time", -1);
  
  if (defined(HEATRONIC_CRCtest($hash,$string,$length)))
  {
    my $year  = 2000 + hex(substr($string,4*2,2));
    my $month = hex(substr($string,5*2,2));
    my $day   = hex(substr($string,7*2,2));
    my $hours = hex(substr($string,6*2,2));
    my $min   = hex(substr($string,8*2,2));
    my $sec   = hex(substr($string,9*2,2));
    my $dow   = hex(substr($string,10*2,2));
#    my $dst     = (hex(substr($string,11*2,2)) & 0x01) ? "dst" : "";

    if (!defined($ch_timeTS))
    {
      $interval_ch_time = -1;
    }
	
    if ($interval_ch_time != 0)
    {
      if (($interval_ch_time > 0) && (HEATRONIC_timeDiff($ch_timeTS) < $interval_ch_time))
      {
        return 1;
      }
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "ch_time", sprintf("%4d-%02d-%02d %02d:%02d:%02d", $year, $month, $day, $hours, $min, $sec ));
      readingsEndUpdate($hash,1);
    }

    return 1;
  }
  else
  {
    return undef;
  }
}



sub
HEATRONIC_DecodeMsg_SOL($$$)
{
  my ($hash,$string,$length) = @_;
  my $name = $hash->{NAME};
  
  my $type;
  
  if (defined(HEATRONIC_CRCtest($hash,$string,$length)))
  {
  
    my $sol_Tcollector     = 0;
    my $sol_Tcylinder_bottom = 0;
    ##################################
    ### message_ID: 259_0_0        ###
    ###  msg: "b000ff000003"       ###
    if (hex(substr($string,5*2,2)) == 3)
    {
      $sol_Tcollector = hex(substr($string,10*2,2));
      if ($sol_Tcollector != 255)
      {
        $sol_Tcollector       = ($sol_Tcollector * 256 + hex(substr($string,11*2,2)))/10;
      }
      else
      {
        $sol_Tcollector       = (255-hex(substr($string,11*2,2)))/-10;
      }
      $sol_Tcylinder_bottom = hex(substr($string,12*2,4))/10;	
    
      my $sol_pump            = (hex(substr($string,14*2,2)) & 0x01) ? 1 : 0;
      my $sol_yield_last_hour = hex(substr($string,8*2,4))/10;

      my $sol_yield_2         = hex(substr($string,6*2,4));
      my $sol_runtime         = hex(substr($string,17*2,4));

      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "sol_Tcollector", $sol_Tcollector);
      readingsBulkUpdate($hash, "sol_Tcylinder_bottom", $sol_Tcylinder_bottom);
      readingsBulkUpdate($hash, "sol_yield_last_hour", $sol_yield_last_hour);
      readingsBulkUpdate($hash, "sol_yield_2", $sol_yield_2);
      readingsBulkUpdate($hash, "sol_pump", $sol_pump);
      readingsBulkUpdate($hash, "sol_runtime", $sol_runtime);
      readingsEndUpdate($hash,1);

      return 1;
    }
    ##################################
    ### message_ID: 260_0_0        ###
    ###  msg: "b000ff000004"       ###
    elsif (hex(substr($string,5*2,2)) == 4)
    {
      my $hybrid_buffer   = hex(substr($string,6*2,4));
      my $hybrid_sysinput = hex(substr($string,8*2,4));

      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "sol_Thybrid_buffer", $hybrid_buffer);
      readingsBulkUpdate($hash, "sol_Thybrid_sysinput", $hybrid_sysinput);
      readingsEndUpdate($hash,1);

      return 1;
    }
    ##################################
    ### message_ID: 866_0_0        ###
    ###  msg: "b000ff000262"       ###
    elsif ((hex(substr($string,4*2,2)) == 2) and (hex(substr($string,5*2,2)) == 0x62))
    {
      $sol_Tcollector = hex(substr($string,6*2,2));
      if ($sol_Tcollector != 255)
      {
        $sol_Tcollector       = ($sol_Tcollector * 256 + hex(substr($string,7*2,2)))/10;
      }
      else
      {
        $sol_Tcollector       = (255-hex(substr($string,7*2,2)))/-10;
      }
      if ($length > 10)
      {
        $sol_Tcylinder_bottom = hex(substr($string,8*2,4))/10;
      }

      # TBD # handling to be defined
      my $sol_pump            = 0;
      if (($sol_Tcollector - $sol_Tcylinder_bottom) >= 5)
      {
        $sol_pump = 1;
      }

      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "sol_Tcollector", $sol_Tcollector);
      if ($length > 10)
      {
        readingsBulkUpdate($hash, "sol_Tcylinder_bottom", $sol_Tcylinder_bottom);
      }
      readingsBulkUpdate($hash, "sol_pump", $sol_pump);
      readingsEndUpdate($hash,1);

      return 1;
    }
    ##################################
    ### message_ID: 910_0_0        ###
    ###  msg: "b000ff00028e"       ###
    elsif ((hex(substr($string,4*2,2)) == 2) and (hex(substr($string,5*2,2)) == 0x8e))
    {

      my $sol_yield_last_hour = hex(substr($string,6*2,8))/10;
      readingsBeginUpdate($hash);
      readingsBulkUpdate($hash, "sol_yield_last_hour", $sol_yield_last_hour);
      readingsEndUpdate($hash,1);

      return 1;
    }
  }
  else
  {
    return undef;
  }
}

sub
HEATRONIC_CRCtest($$$)
{
  my ($hash,$string, $length) = @_;
  my $crc = 0;
  my $i;
  
  return undef if ($length < 3);
   
  for $i (0 .. $length-3)
  {
    $crc = hex($crc_table[$crc]);
    $crc ^= hex(substr($string,$i*2,2));
  }
  
  if ($crc == hex(substr($string,$length*2-4,2)))
  {
    return 1;
  }
  else
  {
    return undef;
  }
}



sub
HEATRONIC_CRCget($)
{
  my ($string) = @_;
  my $crc = 0;
  my $i;
  my $length = length($string)/2;

  for $i (0 .. $length-3)
  {
    $crc = hex($crc_table[$crc]);
    $crc ^= hex(substr($string,$i*2,2));
  }
  
  return "(".sprintf("%02x",$crc) . "/" . substr($string,$length*2-4,2) .")";
}

sub
HEATRONIC_timeDiff($) {
  my ($strTS)=@_;
  
  my $serTS = (defined($strTS) && $strTS ne "") ? time_str2num($strTS) : gettimeofday();
  my $timeDiff = gettimeofday()- $serTS;
  $timeDiff=0 if ( $timeDiff<0);
  return $timeDiff;
}

1;

=pod
=begin html

<a name="HEATRONIC"></a>
<h3>HEATRONIC</h3>

<ul>
     The HEATRONIC module interprets messages received from the HT-Bus of a Junkers Boiler. <br/>
	 Possible Adapters are described in http://www.mikrocontroller.net/topic/317004 (only in german).
	 
	 <br/><br/>
	 <a name="HEATRONIC_Define"></a>
     <B>Define:</B><br/>
	 <ul><code>define &lt;name&gt; HEATRONIC &lt;serial-device | &lt;proxy-server IP-address:port&gt;</code><br/><br/>
	 
	 <B>Example for serial-device:</B></br>
	 <ul>
	   <code> define Boiler HEATRONIC /dev/ttyUSB0@9600</code>
	 </ul><br/>
	 
	 <B>Example for proxy-server:</B></br>
	 <ul>
 	   <code> define Boiler HEATRONIC 192.168.2.11:8088</code>
	 </ul></ul><br/>
	 
	 <a name="HEATRONIC_set"><b>Set:</b></a>
	 <ul>
	   <code>set &lt;name&gt; &lt;param&gt; &lt;value&gt;</code><br/>
       <ul>(only possible with ht_pitiny- or ht_piduino-adapters)</ul><br/>
      where param is one of:
      <ul>
        <li>hc1_Trequested &lt;temp&gt;<br>
          sets the 'heating' temperature-niveau for heating circuit 1 (permanent)<br/>
          0.5 celsius resolution - temperature between 10 and 30 celsius
        </li>
        <li>hc1_mode_requested [ auto | comfort | eco | frost ] (for Fxyz controller)<br>
          sets the working mode for heating circuit 1<br>
          <ul>
            <li>auto   : the timer program is active and the summer configuration is in effect</li>
            <li>comfort: manual by 'comfort' working mode, no timer program is in effect</li>
            <li>eco    : manual by 'eco' working mode, no timer program is in effect</li>
            <li>frost  : manual by 'frost'  working mode, no timer program is in effect</li>
          </ul></li>
        <li>hc1_mode_requested [ auto | manual ] (for Cxyz controller)<br>
          sets the working mode for heating circuit 1<br>
          <ul>
            <li>auto   : the timer program is active and the summer configuration is in effect</li>
            <li>manual : manual working mode, no timer program is in effect</li>
          </ul></li>
      </ul><br/>
      Examples:
      <ul>
        <code>set Boiler hc1_Trequested 22.5</code><br>
        <code>set Boiler hc1_mode_requested eco</code>
      </ul><br/>
	 </ul><br/>
	 
     <a name="HEATRONIC_attributes"><b>Attributes:</b></a>
     <ul>
        <li><B>interval_ch_time, interval_ch_Tflow_measured, interval_dhw_Tmeasured, interval_dhw_Tcylinder</B><br/>
          interval (in seconds) to update the corresponding values
        </li><br/>
        <li><B>minDiff_ch_Tflow_measured</B><br/>
          minimal difference (in degrees, e.g. 0.2) to update the corresponding values
        </li><br/>
        <li><B>ControllerName</B><br/>
          Controller Modulname of heater-system (e.g. FR120 FW200 CW100 CW400)
        </li><br/>
     </ul>
   
	 <a name="HEATRONIC_readings"><b>Readings:</b></a>
	 <ul>
	     <li><B>ch_Tflow_desired</B><br/>
		   required flow temperature (in domestic hot water mode value of max vessel temperature)<br>
		 </li><br/>
	     <li><B>ch_Tflow_measured</B><br/>
		   current measured flow temperature
		 </li><br/>
 	     <li><B>ch_Treturn</B><br/>
		   current measured return temperature
		 </li><br/>
 	     <li><B>ch_Tmixer</B><br/>
		   current measured mixer temperature
		 </li><br/>
 	     <li><B>ch_mode</B><br/>
		   current operation mode (0=off, 1=heating, 2=domestic hot water)
		 </li><br/>
		 <li><B>ch_code</B><br/>
		   current operation code or extended error code (see manual of boiler)
		 </li><br/>
		 <li><B>ch_error</B><br/>
		   error code (see manual of boiler)
		 </li><br/>
	     <li><B>ch_burner_fan</B><br/>
		   status of burner fan (0=off, 1=running)
		 </li><br/>
	     <li><B>ch_burner_operation</B><br/>
		   burner status (0=off, 1=on)
		 </li><br/>
	     <li><B>ch_pump_heating</B><br/>
		   status of the heating pump(0=off, 1=running)
		 </li><br/>
	     <li><B>ch_pump_cylinder</B><br/>
		   status of cylinder loading pump (0=off, 1=running)
		 </li><br/>
	     <li><B>ch_pump_circulation</B><br/>
		   status of circulation pump (0=off, 1=running)
		 </li><br/>
	     <li><B>ch_burner_power</B><br/>
		   burner power in percent
		 </li><br/>
         <li><B>ch_pump_heating_power</B><br/>
		   power of heating power in percent
		 </li><br/>

	     <li><B>ch_Toutside</B><br/>
		   outside temperature
		 </li><br/>
	     <li><B>ch_runtime_total</B><br/>
		   runtime of burner in minutes (heating and domestic hot water)
		 </li><br/>
	     <li><B>ch_runtime_ch</B><br/>
		   runtime of burner in minutes (heating only)
		 </li><br/>
	     <li><B>ch_runtime_dhw</B><br/>
		   runtime of burner in minutes (domestic hot water only)
		 </li><br/>
	     <li><B>ch_starts_tot</B><br/>
		   count of burner operations (heating and domestic hot water)
		 </li><br/>
	     <li><B>ch_starts_ch</B><br/>
		   count of burner operations (heating only)
		 </li><br/>
	     <li><B>ch_starts_dhw</B><br/>
		   count of burner operations (domestic hot water only)
		 </li><br/>
		 <li><B>ch_time</B><br/>
		   system time of boiler
		 </li><br/>
	     <li><B>ch_Thdrylic_switch</B><br/>
		   temperature at hydraulic switch (if available)
		 </li><br/>

		 
	     <li><B>hc1_Tdesired .. hc4_Tdesired</B><br/>
		   required room temperature for heating circuit 1-4
		 </li><br/>
	     <li><B>hc1_Tmeasured .. hc4_Tmeasured</B><br/>
           current measured room temperature for heating circuit 1-4
		 </li><br/>
	     <li><B>hc1_Tmode .. hc4_Tmode</B><br/>
		   operating mode for heating circuit 1-4
		 </li><br/>
	     <li><B>hc1_Tflow_desired .. hc2_Tflow_desired</B><br/>
		   current desired flow-temperatur for heating circuit 1-2
		 </li><br/>
	     <li><B>hc1_pump .. hc2_pump</B><br/>
		   status of circuitpump for heating circuit 1-2 (0=off, 1=running)
		 </li><br/>
	     <li><B>dhw_Tdesired</B><br/>
		   required domestic hot water temperature
		 </li><br/>
	     <li><B>dhw_Tmeasured</B><br/>
		   current measured domestic hot water temperature
		 </li><br/>
	     <li><B>dhw_Tcylinder</B><br/>
		   current measured domestic hot water temperature at the top of the cylinder
		 </li><br/>

	     <li><B>sol_Tcollector</B><br/>
		   temperature of collector groupp 1
		 </li><br/>
	     <li><B>sol_Tcylinder_bottom</B><br/>
		   temperature at the bottom of solar cylinder
		 </li><br/>
	     <li><B>sol_yield_last_hour</B><br/>
		   yield of collector in the last hour
		 </li><br/>
         <li><B>sol_yield_2</B><br/>
		   This value is unkown at the moment. The name can be changed later.
		 </li><br/>
	     <li><B>sol_pump</B><br/>
		   status of solar circuit pump (0=off, 1=running)
		 </li><br/>
	     <li><B>sol_runtime</B><br/>
		    runtime of solar pump in minutes
		 </li><br/>
	 </ul>
</ul>

=end html
=begin html_DE

<a name="HEATRONIC"></a>
<h3>HEATRONIC</h3>

<ul>
     Das HEATRONIC Modul wertet die Nachrichten aus, die &uuml;ber den HT-Bus von einer Junkers-Heizung &uuml;bertragen werden.<br/>
	 M&ouml;gliche Adapter werden unter http://www.mikrocontroller.net/topic/317004 vorgestellt.<br/><br/>
	 
	 <a name="HEATRONIC_Define"></a>
     <B>Define:</B><br/>
	 <ul><code>define &lt;name&gt; HEATRONIC &lt;serial-device&gt;  | &lt;proxy-server IP-Adresse:port&gt;</code><br/><br/>
	 
	 <B>Beispiel f&uuml;r serielles Ger&auml;t:</B></br>
	 <ul>
	   <code> define Heizung HEATRONIC /dev/ttyUSB0@9600</code>
	 </ul><br/>
	 <B>Beispiel f&uuml;r Proxy-Server:</B></br>
	 <ul>
	   <code> define Heizung HEATRONIC 192.168.2.11:8088</code>
	 </ul></ul><br/>

	 <a name="HEATRONIC_set"><b>Set:</b></a>
	 <ul>
      <code>set &lt;name&gt; &lt;param&gt; &lt;value&gt;</code>
      <br><ul>(nur mit ht_pitiny- oder ht_piduino-Adapter m&ouml;glich)</ul>
      <br>
      wobei die Parameter folgende Werte haben:
      <ul>
        <li>hc1_Trequested &lt;temp&gt;<br>
          Setzt das 'Heizen' Temperatur-Niveau f&uuml;r Heizkreis 1 (permanent)<br>
          Aufl&ouml;sung 0.5 Celsius, Bereich: 10 bis 30 Celsius
        </li>
        <li>hc1_mode_requested [ auto | comfort | eco | frost ] (Fxyz Regler)<br>
          Setzt die Betriebsart des Heizkreises 1 bei Fxyz Reglern<br>
          <ul>
            <li>auto   : Das Timerprogramm und die Sommerzeit-Umschaltung sind aktiv </li>
            <li>comfort: Manueller 'comfort' Mode, Timerprogramm deaktiv</li>
            <li>eco    : Manueller 'eco' Mode, Timerprogramm deaktiv</li>
            <li>frost  : Manueller 'frost'  Mode, Timerprogramm deaktiv</li>
          </ul></li>
        <li>hc1_mode_requested [ auto | manual ] (Cxyz Regler)<br>
          Setzt die Betriebsart des Heizkreises 1 bei Cxyz Reglern<br>
          <ul>
            <li>auto   : Das Timerprogramm und die Sommerzeit-Umschaltung sind aktiv </li>
            <li>manual : Manueller Mode, Timerprogramm deaktiv</li>
          </ul></li>
      </ul>
      <br>
      Beispiele:
      <ul>
        <code>set Boiler hc1_Trequested 22.5</code><br>
        <code>set Boiler hc1_mode_requested eco</code>
      </ul>
      <br>
    </ul>
    <br>

     <a name="HEATRONIC_attributes"><b>Attributes:</b></a>
     <ul>
        <li><B>interval_ch_time, interval_ch_Tflow_measured, interval_dhw_Tmeasured, interval_dhw_Tcylinder</B><br/>
          Intervall (in Sekunden) zum Update der entsprechenden Werte
        </li><br/>
        <li><B>minDiff_ch_Tflow_measured</B><br/>
          Minimaldifferenz (in Grad, z.B. 0.2) zum Update der entsprechenden Werte
        </li><br/>
        <li><B>ControllerName</B><br/>
          Controller Modulname des Heizung-Systems (z.B. FR120 FW200 CW100 CW400)
        </li><br/>
     </ul>
	 
	 <a name="HEATRONIC_readings"><b>Readings:</b></a>
	 <ul>
	     <li><B>ch_Tflow_desired</B><br/>
		   ben&ouml;tigte Vorlauf-Temperatur (im Warmwasser-Modus max. Kesseltemperatur)
		 </li><br/>
	     <li><B>ch_Tflow_measured</B><br/>
		   aktuell gemessene Vorlauf-Temperatur
		 </li><br/>
 	     <li><B>ch_Treturn</B><br/>
		   aktuell gemessene R&uuml;cklauf-Temperatur
		 </li><br/>
 	     <li><B>ch_Tmixer</B><br/>
		   aktuell gemessene Mischer-Temperatur
		 </li><br/>
 	     <li><B>ch_mode</B><br/>
		   aktueller Betriebsmodus (0=aus, 1=Heizen, 2=Warmwasser)
		 </li><br/>
		 <li><B>ch_code</B><br/>
		   aktueller Betriebs-Code oder erweiterter St&ouml;rungs-Code (siehe Heizungs-Anleitung) 
		 </li><br/>
		 <li><B>ch_error</B><br/>
		   St&ouml;rungs-Code (siehe Heizungs-Anleitung) 
		 </li><br/>
	     <li><B>ch_burner_fan</B><br/>
		   Status Brenner-Gebl&auml;se (0=aus, 1=l&auml;uft)
		 </li><br/>
	     <li><B>ch_burner_operation</B><br/>
		   Brenner-Status (0=off, 1=an)
		 </li><br/>
	     <li><B>ch_pump_heating</B><br/>
		   Status der Heizungspumpe(0=aus, 1=l&auml;uft)
		 </li><br/>
	     <li><B>ch_pump_cylinder</B><br/>
		   Status der Speicherladepumpe (0=aus, 1=l&auml;uft)
		 </li><br/>
	     <li><B>ch_pump_circulation</B><br/>
		   Status der Zirkulationspumpe (0=aus, 1=l&auml;uft)
		 </li><br/>
	     <li><B>ch_burner_power</B><br/>
		   Brennerleistung in Prozent
		 </li><br/>
         <li><B>ch_pump_heating_power</B><br/>
		   Leistung der Heizungspumpe in Prozent
		 </li><br/>
         
	     <li><B>ch_Toutside</B><br/>
		   Au&szlig;entemperatur
		 </li><br/>
	     <li><B>ch_runtime_total</B><br/>
		   Brennerlaufzeit in Minuten (Heizen und Warmwasser)
		 </li><br/>
	     <li><B>ch_runtime_ch</B><br/>
		   Brennerlaufzeit in Minuten (nur Heizen)
		 </li><br/>
	     <li><B>ch_runtime_dhw</B><br/>
		   Brennerlaufzeit in Minuten (nur Warmwasser)
		 </li><br/>
	     <li><B>ch_starts_tot</B><br/>
		   Anzahl der Brennerstarts (Heizen und Warmwasser)
		 </li><br/>
	     <li><B>ch_starts_ch</B><br/>
		   Anzahl der Brennerstarts (nur Heizen)
		 </li><br/>
	     <li><B>ch_starts_dhw</B><br/>
		   Anzahl der Brennerstarts (nur Warmwasser)
		 </li><br/>
		 <li><B>ch_time</B><br/>
		   Systemzeit der Heizung
		 </li><br/>
	     <li><B>ch_Thdrylic_switch</B><br/>
		   Temperatur an hydraulischer Weiche (wenn vorhanden)
		 </li><br/>
		 
	     <li><B>hc1_Tdesired .. hc4_Tdesired</B><br/>
		   ben&ouml;tigte Raumtemperatur Heizkreis 1-4
		 </li><br/>
	     <li><B>hc1_Tmeasured .. hc4_Tmeasured</B><br/>
           aktuell gemessene Raumtemperatur Heizkreis 1-4
		 </li><br/>
	     <li><B>hc1_Tmode .. hc4_Tmode</B><br/>
		   Betriebsmodus Heizkreis 1-4
		 </li><br/>
	     <li><B>hc1_Tflow_desired .. hc2_Tflow_desired</B><br/>
		   aktuell ben&ouml;tigte Vorlauf-Temperatur Heizkreis 1-2
		 </li><br/>
	     <li><B>hc1_pump .. hc2_pump</B><br/>
		   Status der Heizkreis-Pumpe Heizkreis 1-2 (0=aus, 1=l&auml;uft)
		 </li><br/>
	     <li><B>dhw_Tdesired</B><br/>
		   ben&ouml;tigte Warmwasser-Temperatur
		 </li><br/>
	     <li><B>dhw_Tmeasured</B><br/>
		   aktuell gemessene Warmwasser-Temperatur
		 </li><br/>
	     <li><B>dhw_Tcylinder</B><br/>
		   aktuell gemessene Warmwasser-Temperatur Speicher oben
		 </li><br/>

	     <li><B>sol_Tcollector</B><br/>
		   Temperatur Kollektorgruppe 1
		 </li><br/>
	     <li><B>sol_Tcylinder_bottom</B><br/>
		   Temperatur Solarspeicher unten
		 </li><br/>
	     <li><B>sol_yield_last_hour</B><br/>
		   Kollektorertrag der letzten Stunde
		 </li><br/>
         <li><B>sol_yield_2</B><br/>
		   Der Wert ist noch nicht bekannt. Der Name kann sich noch &auml;ndern.
		 </li><br/>
	     <li><B>sol_pump</B><br/>
		   Status der Solarpumpe (0=off, 1=l&auml;uft)
		 </li><br/>
	     <li><B>sol_runtime</B><br/>
		   Laufzeit der Solarpumpe in Minuten
		 </li><br/>
	 </ul>
</ul>

=end html_DE

=cut
