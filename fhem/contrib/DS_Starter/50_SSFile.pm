########################################################################################################################
# $Id: $
#########################################################################################################################
#       50_SSFile.pm
#
#       (c) 2020 by Heiko Maaz
#       e-mail: Heiko dot Maaz at t-online dot de
#
#       This Module integrate the Synology File Station into FHEM
# 
#       This script is part of fhem.
#
#       Fhem is free software: you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation, either version 2 of the License, or
#       (at your option) any later version.
#
#       Fhem is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License
#       along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
#########################################################################################################################
# 
# Definition: define <name> SSFile <ServerAddr> [ServerPort] [Protocol]
# 
# Example: define SynFile SSFile 192.168.2.20 [5000] [HTTP(S)]
#
package FHEM::SSFile;                                             ## no critic 'package'

use strict;                           
use warnings;
use utf8;
eval "use JSON;1;" or my $SSFileMM = "JSON";                      ## no critic 'eval' # Debian: apt-get install libjson-perl
use Data::Dumper;                                                 # Perl Core module
use GPUtils qw(GP_Import GP_Export);                              # wird für den Import der FHEM Funktionen aus der fhem.pl benötigt
use FHEM::SynoModules::API qw(apistatic);                         # API Modul

use FHEM::SynoModules::SMUtils qw( completeAPI
                                   showAPIinfo
                                   showModuleInfo
                                   addSendqueue
                                   listSendqueue
                                   purgeSendqueue
                                   checkSendRetry
                                   startFunctionDelayed
                                   evaljson
                                   smUrlEncode
                                   getClHash
                                   delClHash
                                   delReadings
                                   setCredentials
                                   getCredentials
                                   showStoredCredentials
                                   setReadingErrorState
                                   setReadingErrorNone 
                                   login
                                   logout
                                   moduleVersion
                                   updQueueLength                                   
                                   trim
                                   slurpFile
                                   jboolmap                                   
                                 );                               # Hilfsroutinen Modul 

use FHEM::SynoModules::ErrCodes qw(expErrors);                    # Error Code Modul                                                      
use MIME::Base64;
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday);
use HttpUtils;                                                    
use Encode;
use File::Find;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
eval "use FHEM::Meta;1" or my $modMetaAbsent = 1;                 ## no critic 'eval'
                                                    
# no if $] >= 5.017011, warnings => 'experimental';

# Run before module compilation
BEGIN {
  # Import from main::
  GP_Import( 
      qw(     
          attr      
          AttrVal
          CancelDelayedShutdown
          CommandSet
          CommandAttr
          CommandDelete
          CommandDefine
          CommandGet
          CommandSetReading
          CommandTrigger
          data
          defs
          devspec2array
          FmtTime
          FmtDateTime
          HttpUtils_NonblockingGet
          init_done
          InternalTimer
          IsDisabled
          Log3 
          modules
          parseParams
          readingFnAttributes          
          ReadingsVal
          RemoveInternalTimer
          readingsBeginUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged 
          readingsEndUpdate
          readingsSingleUpdate
          setKeyValue         
        )
  );
  
  # Export to main context with different name
  #     my $pkg  = caller(0);
  #     my $main = $pkg;
  #     $main =~ s/^(?:.+::)?([^:]+)$/main::$1\_/gx;
  #     foreach (@_) {
  #         *{ $main . $_ } = *{ $pkg . '::' . $_ };
  #     }
  GP_Export(
      qw(
          Initialize
        )
  );  
}

# Versions History intern
my %vNotesIntern = (
  "0.5.0"  => "24.10.2020  new Setter Upload ",
  "0.4.0"  => "18.10.2020  add reqtype to addSendqueue, new Setter prepareDownload ",
  "0.3.0"  => "16.10.2020  create Reading Hash instead of Array ",
  "0.2.0"  => "16.10.2020  some changes in subroutines ",
  "0.1.0"  => "12.10.2020  initial "
);

my %hset = (                                                                # Hash für Set-Funktion (needcred => 1: Funktion benötigt gesetzte Credentials)
  credentials        => { fn => \&_setcredentials,         needcred => 0 },                     
  eraseReadings      => { fn => \&_seteraseReadings,       needcred => 0 },
  listQueue          => { fn => \&listSendqueue,           needcred => 0 },
  logout             => { fn => \&_setlogout,              needcred => 0 },
  purgeQueue         => { fn => \&purgeSendqueue,          needcred => 0 },
  startQueue         => { fn => \&_setstartQueue,          needcred => 1 },
  Download           => { fn => \&_setDownload,            needcred => 1 },
  prepareDownload    => { fn => \&_setDownload,            needcred => 1 },
  Upload             => { fn => \&_setUpload,              needcred => 1 },
  prepareUpload      => { fn => \&_setUpload,              needcred => 1 },
);

my %hget = (                                                                # Hash für Get-Funktion (needcred => 1: Funktion benötigt gesetzte Credentials)
  apiInfo            => { fn => \&_getapiInfo,             needcred => 1 },
  backgroundTaskList => { fn => \&_getbackgroundTaskList,  needcred => 1 }, 
  fileStationInfo    => { fn => \&_getfilestationInfo,     needcred => 1 },
  fileInfo           => { fn => \&_getfileInfo,            needcred => 1 },
  folderList         => { fn => \&_getFolderList,          needcred => 1 },
  storedCredentials  => { fn => \&_getstoredCredentials,   needcred => 1 },
  versionNotes       => { fn => \&_getversionNotes,        needcred => 0 },
);

my %hmodep = (                                                              # Hash für Opmode Parser. 
    fileStationInfo  => { fn => \&_parsefilestationInfo,    doevt => 1 },   # doevt: 1 - Events dürfen ausgelöste werden. 0 - keine Events
    backgroundTask   => { fn => \&_parsebackgroundTaskList, doevt => 1 },
    shareList        => { fn => \&_parseFiFo,               doevt => 1 },
    folderList       => { fn => \&_parseFiFo,               doevt => 0 },
    fileInfo         => { fn => \&_parseFiFo,               doevt => 1 },
    download         => { fn => \&_parseDownload,           doevt => 1 },
    upload           => { fn => \&_parseUpload,             doevt => 1 },
);

# Versions History extern
my %vNotesExtern = (
  "0.1.0"  => "12.10.2020  initial "
);

# Hints EN
my %vHintsExt_en = (
  "1" => "The module integrates Synology File Station with FHEM. "
);

# Hints DE
my %vHintsExt_de = (
  "1" => "Das Modul integriert die Synology File Station in FHEM. "
);

# Standardvariablen
my $splitstr     = "!_ESC_!";                               # Split-String zur Übergabe in getCredentials, login & Co.
my $queueStartFn = "FHEM::SSFile::getApiSites";             # Startfunktion zur Queue-Abarbeitung
my $mbf          = 1048576;                                 # Divisionsfaktor für Megabytes
my $kbf          = 1024;                                    # Divisionsfaktor für Kilobytes
my $found;                                                  # Hash für Ergebnis File::find -> wanted

################################################################
sub Initialize {
 my ($hash) = @_;
 $hash->{DefFn}                 = \&Define;
 $hash->{UndefFn}               = \&Undef;
 $hash->{DeleteFn}              = \&Delete; 
 $hash->{SetFn}                 = \&Set;
 $hash->{GetFn}                 = \&Get;
 $hash->{AttrFn}                = \&Attr;
 $hash->{DelayedShutdownFn}     = \&DelayedShutdown;
 
 # Darstellung FHEMWEB
 # $hash->{FW_summaryFn}        = \&FWsummaryFn;
 #$hash->{FW_addDetailToSummary} = 1 ;                       # zusaetzlich zu der Device-Summary auch eine Neue mit dem Inhalt von DetailFn angezeigt             
 #$hash->{FW_detailFn}           = \&FWdetailFn;
 $hash->{FW_deviceOverview}     = 1;
 
 $hash->{AttrList} = "additionalInfo:multiple-strict,real_path,size,owner,time,perm,mount_point_type,type,volume_status ".
                     "disable:1,0 ".
                     "interval ".
                     "loginRetries:1,2,3,4,5,6,7,8,9,10 ". 
                     "showPassInLog:1,0 ".
                     "timeout ".
                     $readingFnAttributes;   
         
 FHEM::Meta::InitMod( __FILE__, $hash ) if(!$modMetaAbsent);  # für Meta.pm (https://forum.fhem.de/index.php/topic,97589.0.html)

return;   
}

################################################################
# define <name> SSFile 192.168.2.10 [5000] [HTTP(S)] 
#                [1]      [2]        [3]      [4]  
#
################################################################
sub Define {
  my ($hash, $def) = @_;
  
  my $name = $hash->{NAME};
  my $type = $hash->{TYPE};
  
  return "Error: Perl module ".$SSFileMM." is missing. Install it on Debian with: sudo apt-get install libjson-perl" if($SSFileMM);
  
  my @a = split("[ \t][ \t]*", $def);
  
  if(int(@a) < 2) {
      return "You need to specify more parameters.\n". "Format: define <name> SSFile <ServerAddress> [Port] [HTTP(S)] [Tasks]";
  }
  
  shift @a; shift @a;

  my $addr = ($a[0] && $a[0] ne "Tasks") ? $a[0]     : "";
  my $port = ($a[1] && $a[1] ne "Tasks") ? $a[1]     : 5000;
  my $prot = ($a[2] && $a[2] ne "Tasks") ? lc($a[2]) : "http";
  
  my $model = "unspecified";
  
  $hash->{SERVERADDR}            = $addr;
  $hash->{SERVERPORT}            = $port;
  $hash->{MODEL}                 = "Calendar"; 
  $hash->{PROTOCOL}              = $prot;
  $hash->{MODEL}                 = $model;
  $hash->{RESEND}                = "next planned SendQueue start: immediately by next entry";
  $hash->{HELPER}{MODMETAABSENT} = 1 if($modMetaAbsent);                                              # Modul Meta.pm nicht vorhanden  
  
  CommandAttr(undef, "$name room SSFile");

  my $params = {
      hash        => $hash,
      notes       => \%vNotesIntern,
      useAPI      => 1,
      useSMUtils  => 1,
      useErrCodes => 1
  };
  use version 0.77; our $VERSION = moduleVersion ($params);                                           # Versionsinformationen setzen
  
  getCredentials($hash,1,"credentials",$splitstr);                                                    # Credentials lesen
  
  $data{$type}{$name}{sendqueue}{index} = 0;                                                          # Index der Sendequeue initialisieren
    
  initOnBoot($name);                                                                                  # initiale Routinen nach Start ausführen , verzögerter zufälliger Start

return;
}

################################################################
# Die Undef-Funktion wird aufgerufen wenn ein Gerät mit delete 
# gelöscht wird oder bei der Abarbeitung des Befehls rereadcfg, 
# der ebenfalls alle Geräte löscht und danach das 
# Konfigurationsfile neu einliest. 
# Funktion: typische Aufräumarbeiten wie das 
# saubere Schließen von Verbindungen oder das Entfernen von 
# internen Timern, sofern diese im Modul zum Pollen verwendet 
# wurden.
################################################################
sub Undef {
  my $hash = shift;
  my $arg  = shift;
  
  my $name = $hash->{NAME};
  my $type = $hash->{TYPE};
  
  delete $data{$type}{$name};
  
  RemoveInternalTimer($name);
   
return;
}

#######################################################################################################
# Mit der X_DelayedShutdown Funktion kann eine Definition das Stoppen von FHEM verzögern um asynchron 
# hinter sich aufzuräumen.  
# Je nach Rückgabewert $delay_needed wird der Stopp von FHEM verzögert (0|1).
# Sobald alle nötigen Maßnahmen erledigt sind, muss der Abschluss mit CancelDelayedShutdown($name) an 
# FHEM zurückgemeldet werden. 
#######################################################################################################
sub DelayedShutdown {
  my $hash = shift;
  
  my $name = $hash->{NAME};
  my $type = $hash->{TYPE};

  if($hash->{HELPER}{SID}) {
      logout($hash, $data{$type}{$name}{fileapi}, $splitstr);                      # Session alter User beenden falls vorhanden  
      return 1;
  }
  
return 0;
}

#################################################################
# Wenn ein Gerät in FHEM gelöscht wird, wird zuerst die Funktion 
# X_Undef aufgerufen um offene Verbindungen zu schließen, 
# anschließend wird die Funktion X_Delete aufgerufen. 
# Funktion: Aufräumen von dauerhaften Daten, welche durch das 
# Modul evtl. für dieses Gerät spezifisch erstellt worden sind. 
# Es geht hier also eher darum, alle Spuren sowohl im laufenden 
# FHEM-Prozess, als auch dauerhafte Daten bspw. im physikalischen 
# Gerät zu löschen die mit dieser Gerätedefinition zu tun haben. 
#################################################################
sub Delete {
  my ($hash, $arg) = @_;
  my $name  = $hash->{NAME};
  my $index = $hash->{TYPE}."_".$hash->{NAME}."_credentials";
  
  setKeyValue($index, undef);                                                    # gespeicherte Credentials löschen
    
return;
}

################################################################
sub Attr {                             ## no critic 'complexity'
    my ($cmd,$name,$aName,$aVal) = @_;
    my $hash  = $defs{$name};
    my $model = $hash->{MODEL};
    my ($do,$val);
      
    # $cmd can be "del" or "set"
    # $name is device name
    # aName and aVal are Attribute name and value
    
    if ($aName eq "disable") {
        if($cmd eq "set") {
            $do = $aVal ? 1 : 0;
        }
        $do  = 0 if($cmd eq "del");
        $val = ($do ? "disabled" : "initialized");
        
        if ($do) {
            delReadings        ($name, 0);
            RemoveInternalTimer($hash);
        } 
        else {
            InternalTimer(gettimeofday()+2, "FHEM::SSFile::initOnBoot", $hash, 0) if($init_done); 
        }
    
        readingsBeginUpdate($hash); 
        readingsBulkUpdate ($hash, "state", $val);                    
        readingsEndUpdate  ($hash, 1); 
    }
    
return;
}

#############################################################################################
#                                      Setter
#############################################################################################
sub Set {                                                           
  my ($hash, @a) = @_;
  return "\"set X\" needs at least an argument" if ( @a < 2 );
  my $name  = shift @a;
  my $opt   = shift @a;
  my $arg   = join " ", map { my $p = $_; $p =~ s/\s//xg; $p; } @a;     ## no critic 'Map blocks'
  my $prop  = shift @a;
  
  my $model = $hash->{MODEL};
  my $type  = $hash->{TYPE};
  
  my ($success,$setlist);
        
  return if(IsDisabled($name));
  
  my $idxlist = join(",", sort keys %{$data{$type}{$name}{sendqueue}{entries}});
  
  $setlist    = "Unknown argument $opt, choose one of ";
  
  if(!$hash->{CREDENTIALS}) {                                                   # initiale setlist für neue Devices
      $setlist .= "credentials ";  
  } 
  
  if($hash->{CREDENTIALS}) {
      $setlist .= "credentials ".
                  "Download:textField-long ".
                  "Upload:textField-long ".
                  "eraseReadings:noArg ".
                  "listQueue:noArg ".
                  "logout:noArg ".
                  "prepareDownload:textField-long ".
                  "prepareUpload:textField-long ".
                  "startQueue:noArg ".
                  ($idxlist ? "purgeQueue:-all-,-permError-,$idxlist " : "purgeQueue:-all-,-permError- ")
                  ;
  }
  
  my $params = {
      hash  => $hash,
      name  => $name,
      opt   => $opt,
      arg   => $arg,
      prop  => $prop
  };
   
  if($hset{$opt} && defined &{$hset{$opt}{fn}}) {
      my $ret = q{};
      
      if (!$hash->{CREDENTIALS} && $hset{$opt}{needcred}) {                
          return qq{Credentials of $name are not set. Make sure they are set with "set $name credentials <username> <password>"};
      }
  
      $ret = &{$hset{$opt}{fn}} ($params);
      
      return $ret;
  }
  
return "$setlist"; 
}

######################################################################################
#                                   Setter credentials
######################################################################################
sub _setcredentials {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  my $opt   = $paref->{opt};
  my $arg   = $paref->{arg};
  
  return qq{The command "$opt" needs an argument.} if (!$arg); 
  
  my ($a,$h) = parseParams($arg);
  my $user   = $a->[0];
  my $pw     = $a->[1] // q{};
  
  if($hash->{HELPER}{SID}) {
      my $type = $hash->{TYPE};
      logout($hash, $data{$type}{$name}{fileapi}, $splitstr);                # Session alter User beenden falls vorhanden 
  }      
  
  my ($success) = setCredentials($hash, "credentials", $user, $pw, $splitstr);
  
  if($success) {
      return "credentials saved successfully";
  } 
  else {
      return "Error while saving credentials - see logfile for details";
  } 

return;
}

######################################################################################
#                             Setter Download, prepareDownload
######################################################################################
sub _setDownload {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  my $opt   = $paref->{opt};
  my $arg   = $paref->{arg};
  
  if(!$arg) {
      return qq{The command "$opt" needs an argument !}
  }

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  $arg       = smUrlEncode ($arg);
  my ($a,$h) = parseParams ($arg);
  my $fp     = $a->[0];
  
  if(!$fp) {
      return qq{No source file or directory specified for download !}
  }
  
  my @dld = split ",", $fp;
  
  for my $dl (@dld) {
      $dl      =~ s/"//xg;
      my $file = (split "\/", $dl)[-1];
      my $dest = $h->{dest};
      $dl      = qq{"$dl"};
      
      if(!$dest) {
          $dest = $attr{global}{modpath}."/".$file;
      }
      
      if($dest =~ /\/$/x) {
          $dest .= $file;
      }
      
      my $params = { 
          name    => $name,
          opmode  => "download",
          api     => "DOWNLOAD",
          method  => "download",                                                          
          params  => "&path=$dl",
          reqtype => "GET",
          header  => "Accept: application/json",
          dest    => $dest
      };
      
      addSendqueue ($params);
  }
  
  if($opt ne "prepareDownload") {  
      getApiSites ($name);                                    # Queue starten
  }

return;
}

######################################################################################
#                             Setter Upload, prepareUpload
######################################################################################
sub _setUpload {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  my $opt   = $paref->{opt};
  my $arg   = $paref->{arg};
  
  if(!$arg) {
      return qq{The command "$opt" needs an argument !}
  }

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  #$arg       = smUrlEncode ($arg);
  my ($a,$h) = parseParams ($arg);
  my $fp     = $a->[0];
  
  if(!$fp) {
      return qq{No source file or directory specified for upload !}
  }
  
  my $remDir = $h->{dest};
  if(!$remDir) {
      return qq{The command "$opt" needs a destination for upload like "dest=/home/upload" !}
  }
  
  $remDir   =~ s/\/$//x;
  
  my $ow    = $h->{ow}   // "true";                                      # Überschreiben Steuerbit
  my $cdir  = $h->{cdir} // "true";                                      # create Dir Steuerbit
  my $bound = "wNWT9spu8GvTg4TJo1iN";
  
  my @uld   = split ",", $fp;
  
  my @all;
  for my $obj (@uld) {                                                   # nicht existierende objekte aussondern
      if (! -e $obj) {
          Log3 ($name, 3, qq{$name - The object "$obj" doesn't exist, ignore it for upload});
          next;
      }
      push @all, $obj;
  } 
  
  undef $found;
  for my $obj (@all) {                                                   # Objekte und Inhalte der Ordner auslesen für add Queue
      find ( { wanted => \&wanted, no_chdir => 1 }, $obj );
  }
  
  Log3 ($name, 3, "$name - all explored files for upload:\n".Dumper $found);

  for my $lcf (keys %{$found}) {
      my $fname = (split "\/", $lcf)[-1];
      my $dir   = $remDir.$found->{"$lcf"};                             # zusammengesetztes Zielverzeichnis
      
      my $dat;
      $dat .= addBodyPart ($bound, qq{content-disposition: form-data; name="path"},                                                              $dir,     "first");
      $dat .= addBodyPart ($bound, qq{content-disposition: form-data; name="create_parents"},                                                    $cdir            );
      $dat .= addBodyPart ($bound, qq{content-disposition: form-data; name="overwrite"},                                                         $ow              );
      $dat .= addBodyPart ($bound, qq{content-disposition: form-data; name="file"; filename="$fname"\r\nContent-Type: application/octet-stream}, "<FILE>", "last" );
      
      my $params = { 
          name     => $name,
          opmode   => "upload",
          api      => "UPLOAD",
          method   => "upload",                                                          
          reqtype  => "POST",
          header   => "Content-Type: multipart/form-data, boundary=$bound",
          lclFile  => $lcf,
          postdata => $dat
      };
      
      addSendqueue ($params);
  }
  
  if($opt ne "prepareUpload") {  
      getApiSites ($name);                                              # Queue starten
  }

return;
}

######################################################################################
#                             Setter startQueue
######################################################################################
sub _setstartQueue {
  my $paref = shift;
  my $name  = $paref->{name};
  
  my $ret   = getApiSites($name);
  
  if($ret) {
      return $ret;
  } 
  else {
      return "The SendQueue has been restarted.";
  }  

return;
}

######################################################################################
#                             Setter eraseReadings
######################################################################################
sub _seteraseReadings {
  my $paref = shift;
  my $name  = $paref->{name};
  
  delReadings($name, 0);                                            # Readings löschen  

return;
}

######################################################################################
#                             Setter logout
######################################################################################
sub _setlogout {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  
  my $type  = $hash->{TYPE};
  
  logout($hash, $data{$type}{$name}{fileapi}, $splitstr); 

return;
}

######################################################################################
#                                      Getter
######################################################################################
sub Get {                                                   
    my ($hash, @a) = @_;
    return "\"get X\" needs at least an argument" if ( @a < 2 );
    my $name = shift @a;
    my $opt  = shift @a;
    my $arg  = join " ", map { my $p = $_; $p =~ s/\s//xg; $p; } @a;     ## no critic 'Map blocks'
    
    my $getlist;

    if(!$hash->{CREDENTIALS}) {
        return;    
    } 
    else {
        $getlist = "Unknown argument $opt, choose one of ".
                   "apiInfo:noArg ".
                   "backgroundTaskList:noArg ".
                   "fileStationInfo:noArg ".
                   "folderList ".
                   "fileInfo:textField-long ".
                   "storedCredentials:noArg ".
                   "versionNotes " 
                   ;
    }
          
    return if(IsDisabled($name));  

    my $params = {
        hash  => $hash,
        name  => $name,
        opt   => $opt,
        arg   => $arg
    };
  
    if($hget{$opt} && defined &{$hget{$opt}{fn}}) {
        my $ret = q{};
      
        if (!$hash->{CREDENTIALS} && $hget{$opt}{needcred}) {                
            return qq{Credentials of $name are not set. Make sure they are set with "set $name credentials <username> <password>"};
        }
  
        $ret = &{$hget{$opt}{fn}} ($params);
      
        return $ret;
    }

return $getlist;
}

######################################################################################
#                             Getter storedCredentials
######################################################################################
sub _getstoredCredentials {
  my $paref = shift;
  my $hash  = $paref->{hash};
  
  my $out = showStoredCredentials ($hash, 1, $splitstr);
  
return $out;
}

######################################################################################
#                             Getter apiInfo
#           Informationen der verwendeten API abrufen und anzeigen 
######################################################################################
sub _getapiInfo {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  
  delClHash ($name);
  getClHash ($hash,1);                                                # übergebenen CL-Hash (FHEMWEB) in Helper eintragen 

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter
  
  my $params = { 
      name    => $name,
      opmode  => "apiInfo",
      api     => "",
      method  => "",
      params  => "",
      reqtype => "GET",
      header  => "Accept: application/json"
  };
  
  addSendqueue ($params);            
  getApiSites  ($name);

return;
}

######################################################################################
#                             Getter fileStationInfo
#                Informationen der File Station abrufen 
######################################################################################
sub _getfilestationInfo {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  my $params = { 
      name    => $name,
      opmode  => "fileStationInfo",
      api     => "FSINFO",
      method  => "get",                                                            # Methode get statt getinfo -> Fehler in Docu !
      params  => "",
      reqtype => "GET",
      header  => "Accept: application/json"
  };
  
  addSendqueue ($params);            
  getApiSites  ($name);

return;
}

######################################################################################
#                             Getter backgroundTaskList
#    Informationen über Operationen der File Station die im Hintergrund laufen
######################################################################################
sub _getbackgroundTaskList {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  my $params = { 
      name    => $name,
      opmode  => "backgroundTask",
      api     => "BGTASK",
      method  => "list",                                                          
      params  => "",
      reqtype => "GET",
      header  => "Accept: application/json"
  };
  
  addSendqueue ($params);            
  getApiSites  ($name);

return;
}

######################################################################################
#                             Getter folderList
#  Alle freigegebenen Ordner auflisten, Dateien in einem freigegebenen Ordner 
#  aufzählen und detaillierte Dateiinformationen erhalten
######################################################################################
sub _getFolderList {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  my $arg   = $paref->{arg};
  
  my $params;
  
  my $adds = AttrVal($name, "additionalInfo", ""); 

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  if ($arg) {
      $arg       = smUrlEncode ($arg);
      my ($a,$h) = parseParams ($arg);
      my $fp     = $a->[0];
      my $mo     = q{};
      
      while (my ($k,$v) = each %$h) {                                   # Zusatzoptionen z.B. filetype=file
          $mo .= "&".$k."=".$v;
      }
      
      $params = { 
          name   => $name,
          opmode => "folderList",
          api    => "LIST",
          method => "list",                                                          
          params => "&additional=$adds&folder_path=$fp".$mo,
          reqtype => "GET"
      };
  }
  else {
      $params = { 
          name    => $name,
          opmode  => "shareList",
          api     => "LIST",
          method  => "list_share",                                                          
          params  => "&additional=$adds",
          reqtype => "GET",
          header  => "Accept: application/json",
      };   
  }
  
  addSendqueue ($params);            
  getApiSites  ($name);

return;
}

######################################################################################
#                             Getter filefolderInfo
#                 Informationen über die Datei(en) erhalten 
######################################################################################
sub _getfileInfo {
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $name  = $paref->{name};
  my $opt   = $paref->{opt};
  my $arg   = $paref->{arg};
  
  if(!$arg) {
      return qq{The command "$opt" needs an argument !}
  }
  
  my $params;
  
  my $adds = AttrVal($name, "additionalInfo", ""); 

  # Schema:  name   => Name, 
  #          opmode => operation mode, 
  #          api    => API (siehe $data{$type}{$name}{fileapi}), 
  #          method => auszuführende API-Methode, 
  #          params => "spezifische API-Parameter>
  
  $arg       = smUrlEncode ($arg);
  my ($a,$h) = parseParams ($arg);
  my $fp     = $a->[0];
  my $mo     = q{};
  
  while (my ($k,$v) = each %$h) {                                   # Zusatzoptionen z.B. filetype=file
      $mo .= "&".$k."=".$v;
  }
  
  $params = { 
      name    => $name,
      opmode  => "fileInfo",
      api     => "LIST",
      method  => "getinfo",                                                          
      params  => "&additional=$adds&path=$fp".$mo,
      reqtype => "GET",
      header  => "Accept: application/json"
  };
  
  addSendqueue ($params);            
  getApiSites  ($name);

return;
}

######################################################################################
#                             Getter versionNotes
######################################################################################
sub _getversionNotes {
  my $paref = shift;

  $paref->{hintextde} = \%vHintsExt_de;
  $paref->{hintexten} = \%vHintsExt_en;
  $paref->{notesext}  = \%vNotesExtern;
 
  my $ret = showModuleInfo ($paref);
                    
return $ret;
}

######################################################################################
#                   initiale Startroutinen nach Restart FHEM
######################################################################################
sub initOnBoot {
  my ($name) = @_;
  my $hash   = $defs{$name};
  my ($ret);
  
  RemoveInternalTimer($name, "FHEM::SSFile::initOnBoot");
  
  if ($init_done) {
      readingsBeginUpdate($hash);
      readingsBulkUpdate ($hash, "Errorcode"  , "none");
      readingsBulkUpdate ($hash, "Error"      , "none");   
      readingsBulkUpdate ($hash, "QueueLength", 0);                                              # Länge Sendqueue initialisieren
      readingsBulkUpdate ($hash, "nextUpdate" , "undefined");                                    # Abrufmode initialisieren   
      readingsBulkUpdate ($hash, "state"      , "Initialized");                                  # Init state
      readingsEndUpdate  ($hash,1);              
  } 
  else {
      InternalTimer(gettimeofday()+3, "FHEM::SSFile::initOnBoot", $name, 0);
  }
  
return;
}

#############################################################################################
#      regelmäßiger Intervallabruf
#############################################################################################
sub periodicCall {
  my $name     = shift;
  my $hash     = $defs{$name};
  
  RemoveInternalTimer($name,"FHEM::SSFile::periodicCall");
  
  my $interval = AttrVal($name, "interval", 0);
  
  my $new;
   
  if(!$interval) {
      $hash->{MODE} = "Manual";
      readingsSingleUpdate($hash, "nextUpdate", "manual", 1);
      return;
  } 
  else {
      $new = gettimeofday()+$interval;
      readingsBeginUpdate ($hash);
      readingsBulkUpdate  ($hash, "nextUpdate", "Automatic - next polltime: ".FmtTime($new));     # Abrufmode initial auf "Manual" setzen   
      readingsEndUpdate   ($hash,1);
      
      $hash->{MODE} = "Automatic";
  }
  
  if($hash->{CREDENTIALS} && !IsDisabled($name)) {
 
  }
  
  InternalTimer($new, "FHEM::SSFile::periodicCall", $name, 0);
    
return;  
}

####################################################################################
#                    Einstiegsfunktion Queue Abarbeitung
####################################################################################
sub getApiSites {
   my $name = shift;
   my $hash = $defs{$name};
   my $addr = $hash->{SERVERADDR};
   my $port = $hash->{SERVERPORT};
   my $prot = $hash->{PROTOCOL}; 

   my $type = $hash->{TYPE};   
   
   my ($url,$idxset,$ret);
   
   $hash->{HELPER}{LOGINRETRIES} = 0;

   if(!keys %{$data{$type}{$name}{sendqueue}{entries}}) {
       $ret = "Sendqueue is empty. Nothing to do ...";
       Log3($name, 4, "$name - $ret"); 
       return $ret;  
   }
   
   # den nächsten Eintrag aus "SendQueue" selektieren und ausführen wenn nicht forbidSend gesetzt ist
   for my $idx (sort{$a<=>$b} keys %{$data{$type}{$name}{sendqueue}{entries}}) {
       if (!$data{$type}{$name}{sendqueue}{entries}{$idx}{forbidSend}) {
           $hash->{OPIDX}  = $idx;
           $hash->{OPMODE} = $data{$type}{$name}{sendqueue}{entries}{$idx}{opmode};
           $idxset         = 1;
           last;
       }               
   }
   
   if(!$idxset) {
       $ret = qq{Only entries with "forbidSend" are in Sendqueue. Escaping ...};
       Log3($name, 4, "$name - $ret"); 
       return $ret; 
   }
   
   Log3($name, 4, "$name - ####################################################"); 
   Log3($name, 4, "$name - ### start Synology File operation $hash->{OPMODE}   "); 
   Log3($name, 4, "$name - ####################################################");
   
   readingsBeginUpdate ($hash);                   
   readingsBulkUpdate  ($hash, "state", "running");                    
   readingsEndUpdate   ($hash,1);
   
   if ($hash->{OPMODE} eq "apiInfo") {
       $data{$type}{$name}{fileapi}{PARSET} = 0;                                             # erzwinge Abruf API 
   }
   
   if ($data{$type}{$name}{fileapi}{PARSET}) {                                               # API-Hashwerte sind bereits gesetzt -> Abruf überspringen
       Log3($name, 4, "$name - API hash values already set - ignore get apisites");
       return checkSID($name);
   }

   my $timeout = AttrVal($name,"timeout",20);
   Log3($name, 5, "$name - HTTP-Call will be done with timeout: $timeout s");
   
   # API initialisieren und abrufen
   ####################################
   $data{$type}{$name}{fileapi} = apistatic ("file");                                    # API Template im HELPER instanziieren
   
   Log3 ($name, 4, "$name - API imported:\n".Dumper $data{$type}{$name}{fileapi});
     
   my @ak;
   for my $key (keys %{$data{$type}{$name}{fileapi}}) {
       next if($key =~ /^PARSET$/x);  
       push @ak, $data{$type}{$name}{fileapi}{$key}{NAME};
   }
   my $apis = join ",", @ak;

   my $fileapi = $data{$type}{$name}{fileapi};
   
   $url        = "$prot://$addr:$port/webapi/$data{$type}{$name}{fileapi}{INFO}{PATH}?".
                 "api=$data{$type}{$name}{fileapi}{INFO}{NAME}".
                 "&method=Query".
                 "&version=$data{$type}{$name}{fileapi}{INFO}{VER}".
                 "&query=$apis";

   Log3($name, 4, "$name - Call-Out: $url");
   
   my $param = {
       url      => $url,
       timeout  => $timeout,
       hash     => $hash,
       method   => "GET",
       header   => "Accept: application/json",
       callback => \&FHEM::SSFile::getApiSites_parse
   };
            
   HttpUtils_NonblockingGet ($param);  

return;
} 

####################################################################################  
#      Auswertung Abruf apisites
####################################################################################
sub getApiSites_parse {                                    ## no critic 'complexity'
   my ($param, $err, $myjson) = @_;
   my $hash   = $param->{hash};
   my $name   = $hash->{NAME};
   my $opmode = $hash->{OPMODE};
   
   my $type   = $hash->{TYPE};

   my ($error,$errorcode,$success);
  
    if ($err ne "") {                                                                       # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
        Log3($name, 2, "$name - ERROR message: $err");
       
        setReadingErrorState ($hash, $err);         
        checkSendRetry       ($name, 1, $queueStartFn);
        return;
    } 
    elsif ($myjson ne "") {          
        ($success) = evaljson($hash,$myjson);
        
        if (!$success) {
            Log3           ($name, 4, "$name - Data returned: ".$myjson);
            checkSendRetry ($name, 1, $queueStartFn);       
            return;
        }
        
        my $jdata = decode_json($myjson);
        
        Log3($name, 5, "$name - JSON returned: ". Dumper $jdata);
   
        $success = $jdata->{'success'};
    
        if ($success) {
            my $completed = completeAPI ($jdata, $data{$type}{$name}{fileapi});              # übergibt Referenz zum instanziierten API-Hash            

            if(!$completed) {
                $errorcode = "9001";
                $error     = expErrors($hash,$errorcode);                                   # Fehlertext zum Errorcode ermitteln
                
                setReadingErrorState ($hash, $error, $errorcode);
                Log3($name, 2, "$name - ERROR - $error");                    
                
                checkSendRetry ($name, 1, $queueStartFn);    
                return;                
            }
            
            # Downgrades für nicht kompatible API-Versionen. Hier nur nutzen wenn API zentral downgraded werden soll            
            Log3($name, 4, "$name - ------- Begin of adaption section -------");
            
            my @sims;
            
            push @sims, "LIST:1";
            push @sims, "UPLOAD:2";
            
            for my $esim (@sims) {
                my($k,$v) = split ":", $esim;
                $data{$type}{$name}{fileapi}{$k}{VER} = $v;
                $data{$type}{$name}{fileapi}{$k}{MOD} = "yes";
                Log3($name, 4, "$name - Version of $data{$type}{$name}{fileapi}{$k}{NAME} adapted to: $data{$type}{$name}{fileapi}{$k}{VER}");
            }
            
            Log3($name, 4, "$name - ------- End of adaption section -------");
            
            setReadingErrorNone($hash, 1);

            Log3 ($name, 4, "$name - API completed:\n".Dumper $data{$type}{$name}{fileapi});   

            if ($opmode eq "apiInfo") {                                             # API Infos in Popup anzeigen
                showAPIinfo          ($hash, $data{$type}{$name}{fileapi});          # übergibt Referenz zum instanziierten API-Hash)
                readingsSingleUpdate ($hash, "state", "done", 1);  
                checkSendRetry       ($name, 0, $queueStartFn);
                return;
            }          
        } 
        else {
            $errorcode = "806";
            $error     = expErrors($hash,$errorcode);                               # Fehlertext zum Errorcode ermitteln
            
            readingsBeginUpdate         ($hash);
            readingsBulkUpdateIfChanged ($hash, "Errorcode", $errorcode);
            readingsBulkUpdateIfChanged ($hash, "Error",     $error);
            readingsBulkUpdate          ($hash, "state",     "Error");
            readingsEndUpdate           ($hash, 1);

            Log3($name, 2, "$name - ERROR - the API-Query couldn't be executed successfully");                    
            
            checkSendRetry ($name, 1, $queueStartFn);    
            return;
        }
    }
    
return checkSID($name);
}

#############################################################################################
#                                     Ausführung Operation
#############################################################################################
sub execOp {  
   my $name     = shift;
   my $hash     = $defs{$name};
   my $prot     = $hash->{PROTOCOL};
   my $addr     = $hash->{SERVERADDR};
   my $port     = $hash->{SERVERPORT};
   my $sid      = $hash->{HELPER}{SID};
   
   my $type     = $hash->{TYPE};
      
   my $idx      = $hash->{OPIDX};
   my $opmode   = $hash->{OPMODE};
   my $method   = $data{$type}{$name}{sendqueue}{entries}{$idx}{method};
   my $api      = $data{$type}{$name}{sendqueue}{entries}{$idx}{api};
   my $params   = $data{$type}{$name}{sendqueue}{entries}{$idx}{params};
   my $reqtype  = $data{$type}{$name}{sendqueue}{entries}{$idx}{reqtype};
   my $header   = $data{$type}{$name}{sendqueue}{entries}{$idx}{header};
   my $postdata = $data{$type}{$name}{sendqueue}{entries}{$idx}{postdata};
   my $fileapi  = $data{$type}{$name}{fileapi};
   
   my ($url,$timeout,$param,$error,$errorcode);

   Log3($name, 4, "$name - start SendQueue entry index \"$idx\" ($hash->{OPMODE}) for operation."); 

   $timeout = AttrVal($name, "timeout", 20);
   
   Log3($name, 5, "$name - HTTP-Call will be done with timeout: $timeout s");
   
   $param = {
       timeout  => $timeout,
       hash     => $hash,
       method   => $reqtype,
       header   => $header,
       callback => \&FHEM::SSFile::execOp_parse
   };
        
   if($reqtype eq "GET") {
       $url = "$prot://$addr:$port/webapi/".$fileapi->{$api}{PATH}."?api=".$fileapi->{$api}{NAME}."&version=".$fileapi->{$api}{VER}."&method=$method".$params."&_sid=$sid";

       logUrl ($name, $url);
       
       $param->{url} = $url;
   }
   
   if($reqtype eq "POST") {
       $url = "$prot://$addr:$port/webapi/".$fileapi->{$api}{PATH}."?api=".$fileapi->{$api}{NAME}."&version=".$fileapi->{$api}{VER}."&method=$method&_sid=$sid";

       logUrl ($name, $url);  

       my $lclFile = $data{$type}{$name}{sendqueue}{entries}{$idx}{lclFile};       
       
       Log3($name, 5, "$name - POST data (string <FILE> will be replaced with content of $lclFile):\n$postdata");
       
       ($errorcode, my $content) = slurpFile ($name, $lclFile);
       
       if($errorcode) {
           $error = expErrors   ($hash, $errorcode           );
           setReadingErrorState ($hash, $error, $errorcode   );
           checkSendRetry       ($name, 1,      $queueStartFn); 
           return;          
       }
       
       $postdata =~ s/<FILE>/$content/xs;
       
       $param->{url}  = $url;
       $param->{data} = $postdata;
   }
   
   HttpUtils_NonblockingGet ($param);

return;   
} 
  
#############################################################################################
#                                Callback from execOp
#############################################################################################
sub execOp_parse {                                                   
   my $param  = shift;
   my $err    = shift;
   my $myjson = shift;
   my $hash   = $param->{hash};
   my $head   = $param->{httpheader};
   my $name   = $hash->{NAME};
   my $prot   = $hash->{PROTOCOL};
   my $addr   = $hash->{SERVERADDR};
   my $port   = $hash->{SERVERPORT};
   my $opmode = $hash->{OPMODE};
   
   my $type   = $hash->{TYPE};

   my ($jdata,$success,$error,$errorcode,$cherror);
   
   if ($err ne "") {                                                              # wenn ein Fehler bei der HTTP Abfrage aufgetreten ist
        Log3($name, 2, "$name - ERROR message: $err");
        
        $errorcode = "none";
        $errorcode = "800" if($err =~ /:\smalformed\sor\sunsupported\sURL$/xs);

        readingsBeginUpdate         ($hash); 
        readingsBulkUpdateIfChanged ($hash, "Error",           $err);
        readingsBulkUpdateIfChanged ($hash, "Errorcode", $errorcode);
        readingsBulkUpdate          ($hash, "state",        "Error");                    
        readingsEndUpdate           ($hash,1);         

        checkSendRetry ($name, 1, $queueStartFn);        
        return;
   } 
   elsif ($myjson ne "") {                                                     # wenn die Abfrage erfolgreich war ($data enthält die Ergebnisdaten des HTTP Aufrufes)
        if($opmode ne "download") {
            ($success) = evaljson($hash,$myjson);        
            
            if (!$success) {
                Log3           ($name, 4, "$name - Data returned: ".$myjson);
                checkSendRetry ($name, 1, $queueStartFn);       
                return;
            }
            
            $jdata = decode_json($myjson);
            
            Log3($name, 5, "$name - JSON returned: ". Dumper $jdata);
       
            $success = $jdata->{'success'};
        }
        else {                                                                # Opmode download bringt File kein JSON
            $success = 1;
            $jdata   = $myjson;
        }
        
        if ($success) {
            my %ra;                                                           # Hash für Ergebnisreadings
            my $ret = q{};
            
            $error    = "none";
            my $state = "done";
            
            my $params = {
                hash  => $hash,
                param => $param,
                jdata => $jdata,
                href  => \%ra,
            };
            
            if($hmodep{$opmode} && defined &{$hmodep{$opmode}{fn}}) {
                $ret = &{$hmodep{$opmode}{fn}} ($params) // q{};              
            } 
            else {
                Log3($name, 1, qq{$name - ERROR - no operation parse function found for "$opmode"});
                checkSendRetry ($name, 0, $queueStartFn);
                return;
            }
            
            _createReadings ($name, $ret, \%ra);         
        } 
        else {                                                                        # die API-Operation war fehlerhaft
            Log3 ($name, 5, "$name - Header returned:\n".$head);
            
            $errorcode = $jdata->{error}->{code};
            $cherror   = $jdata->{error}->{errors};                                   
            $error     = expErrors($hash,$errorcode);                                 # Fehlertext zum Errorcode ermitteln
            
            if ($error =~ /not found/) {
                $error .= " New error: ".($cherror // "'  '");
            }
            
            setReadingErrorState ($hash, $error, $errorcode);
       
            Log3($name, 2, "$name - ERROR - Operation $opmode was not successful. Errorcode: $errorcode - $error");
            
            checkSendRetry ($name, 1, $queueStartFn);
        }
                
       undef $myjson;
       undef $jdata;
   }

return;
}

#############################################################################################
#        erstellt Readings aus einem übergebenen Reading Hashref ($href)
#############################################################################################
sub _createReadings { 
  my $name      = shift;
  my $ret       = shift;
  my $href      = shift;
  
  my $hash      = $defs{$name};
  my $type      = $hash->{TYPE};
  
  my $error     = "none";
  my $errorcode = "none";
  my $state     = "done";
  
  if($ret) {
      $errorcode = $ret;
      $error     = expErrors($hash,$errorcode);                             # Fehlertext zum Errorcode ermitteln
      $state     = "Error";
  }
  
  my $opmode     = $hash->{OPMODE};
  my $evt        = $hmodep{$opmode}{doevt};

  readingsBeginUpdate         ($hash);

  $data{$type}{$name}{lastUpdate} = FmtDateTime($hash->{".updateTime"});    # letzte Updatezeit speichern

  while (my ($k, $v) = each %$href) {
      readingsBulkUpdate ($hash, $k, $v);
  }
  readingsEndUpdate           ($hash, $evt);

  readingsBeginUpdate         ($hash);
  readingsBulkUpdateIfChanged ($hash, "Errorcode",  $errorcode   );
  readingsBulkUpdateIfChanged ($hash, "Error",      $error       );
  readingsBulkUpdate          ($hash, "lastUpdate", FmtTime(time));            
  readingsBulkUpdate          ($hash, "state",      $state       );                    
  readingsEndUpdate           ($hash, 1);   

  delReadings($name,1) if($data{$type}{$name}{lastUpdate});                 # Readings löschen wenn Timestamp nicht "lastUpdate"

  checkSendRetry ($name, 0, $queueStartFn);

return;
}

#############################################################################################
#                              File Station Info parsen
#############################################################################################
sub _parsefilestationInfo { 
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $jdata = $paref->{jdata};
  my $href  = $paref->{href};
  
  my $name  = $hash->{NAME};

  my $is_manager = jboolmap ($jdata->{data}{is_manager});
  my $hostname   = $jdata->{data}{hostname};
  my $svfs       = jboolmap ($jdata->{data}{support_vfs});
  my $sfr        = jboolmap ($jdata->{data}{support_file_request});
  my $sshare     = jboolmap ($jdata->{data}{support_sharing});
  my $eisom      = jboolmap ($jdata->{data}{support_virtual}{enable_iso_mount});
  my $remom      = jboolmap ($jdata->{data}{support_virtual}{enable_remote_mount});
  my $uid        = $jdata->{data}{uid};
  my $cp         = $jdata->{data}{system_codepage};
  my $sproto     = join ",", @{$jdata->{data}{support_virtual_protocol}};
  
  $href->{IsUserManager}        = $is_manager;
  $href->{Hostname}             = $hostname;
  $href->{Support_vfs}          = $svfs;
  $href->{Support_filerequest}  = $sfr;
  $href->{Support_sharing}      = $sshare;
  $href->{Support_protocols}    = $sproto;
  $href->{UID}                  = $uid;
  $href->{SystemCodepage}       = $cp;
  $href->{Enabled_iso_mount}    = $eisom;
  $href->{Enabled_remote_mount} = $remom;
   
return;
}

#############################################################################################
#                   File Station laufende Background Tasks parsen
#############################################################################################
sub _parsebackgroundTaskList { 
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $jdata = $paref->{jdata};
  my $href  = $paref->{href};
  
  my $name  = $hash->{NAME};

  my $total = $jdata->{data}{total};
  my $tasks = join ",\n", @{$jdata->{data}{tasks}};
  
  $tasks    =  $tasks ? $tasks : "no running tasks"; 
  
  $href->{BackgroundTasksNum} = $total;
  $href->{BackgroundTasks}    = $tasks;
   
return;
}

#############################################################################################
#                              File / Folder Info parsen Intro
#############################################################################################
sub _parseFiFo { 
  my $paref  = shift;
  my $hash   = $paref->{hash};
  my $jdata  = $paref->{jdata};
  my $href   = $paref->{href};                             # Hash Referenz für Ergebnisreadings
  
  my $name   = $hash->{NAME};
  my $opmode = $hash->{OPMODE};
  
  my $qal;

  if($opmode eq "shareList") {
      $qal = "shares";
  }
  elsif ($opmode eq "folderList") {
      $qal = "files";
  }
  elsif ($opmode eq "fileInfo") {
      $qal = "files";
  }
  else  {
      Log3($name, 1, "$name - ERROR - no valid operation mode set for function ".(caller(0))[3]);
      return;
  }
  
  my $total = $jdata->{data}{total} // $jdata->{data}{$qal} ? scalar(@{$jdata->{data}{$qal}}) : 0;
  my $len   = length $total;
  
  my $params = {
      name  => $name,
      jdata => $jdata,
      total => $total,
      len   => $len,
      qal   => $qal,
      href  => $href
  };
  
  my $ec = __createKeyValueHash ($params);
  
  return $ec if($ec);
   
return;
}

#############################################################################################
#                              File / Folder Info parsen
#############################################################################################
sub __createKeyValueHash {
  my $paref = shift;
  my $name  = $paref->{name};
  my $jdata = $paref->{jdata};
  my $total = $paref->{total};
  my $len   = $paref->{len};
  my $qal   = $paref->{qal};
  my $href  = $paref->{href};
  
  my $adds  = AttrVal($name, "additionalInfo", "");
  
  for (my $i=0; $i<$total; $i++) {
      if($jdata->{data}{$qal}[$i]{code}) {
          return ($jdata->{data}{$qal}[$i]{code});                    # File not found bei "getinfo" File
      } 
  
      $href->{sprintf("%0$len.0f", $i+1)."_IsDir"}          = jboolmap ($jdata->{data}{$qal}[$i]{isdir})                                  if(defined $jdata->{data}{$qal}[$i]{isdir});
      $href->{sprintf("%0$len.0f", $i+1)."_Path"}           = encode("utf8", $jdata->{data}{$qal}[$i]{path})                              if(defined $jdata->{data}{$qal}[$i]{path});
      $href->{sprintf("%0$len.0f", $i+1)."_Path_real"}      = encode("utf8", $jdata->{data}{$qal}[$i]{additional}{real_path})             if(defined $jdata->{data}{$qal}[$i]{additional}{real_path});
      $href->{sprintf("%0$len.0f", $i+1)."_Type"}           = $jdata->{data}{$qal}[$i]{additional}{type}                                  if($jdata->{data}{$qal}[$i]{additional}{type});      
      $href->{sprintf("%0$len.0f", $i+1)."_MBytes_total"}   = int $jdata->{data}{$qal}[$i]{additional}{volume_status}{totalspace} / $mbf  if(defined $jdata->{data}{$qal}[$i]{additional}{volume_status}{totalspace});
      $href->{sprintf("%0$len.0f", $i+1)."_MBytes_free"}    = int $jdata->{data}{$qal}[$i]{additional}{volume_status}{freespace} / $mbf   if(defined $jdata->{data}{$qal}[$i]{additional}{volume_status}{freespace});
      $href->{sprintf("%0$len.0f", $i+1)."_MBytes_Size"}    = sprintf("%0.3f", $jdata->{data}{$qal}[$i]{additional}{size} / $mbf)         if(defined $jdata->{data}{$qal}[$i]{additional}{size});
      $href->{sprintf("%0$len.0f", $i+1)."_Readonly"}       = jboolmap ($jdata->{data}{$qal}[$i]{additional}{volume_status}{readonly})    if(defined $jdata->{data}{$qal}[$i]{additional}{volume_status}{readonly});
      $href->{sprintf("%0$len.0f", $i+1)."_MountpointType"} = $jdata->{data}{$qal}[$i]{additional}{mount_point_type}                      if(defined $jdata->{data}{$qal}[$i]{additional}{mount_point_type});
      
      if($jdata->{data}{$qal}[$i]{additional}{perm}{acl}) {
          $href->{sprintf("%0$len.0f", $i+1)."_Perm_Posix"}  = $jdata->{data}{$qal}[$i]{additional}{perm}{posix};
          $href->{sprintf("%0$len.0f", $i+1)."_Perm_Share"}  = $jdata->{data}{$qal}[$i]{additional}{perm}{share_right};
          $href->{sprintf("%0$len.0f", $i+1)."_Is_ACL_Mode"} = jboolmap ($jdata->{data}{$qal}[$i]{additional}{perm}{is_acl_mode});
          
          my @acl;
          while (my ($k,$v) = each %{$jdata->{data}{$qal}[$i]{additional}{perm}{acl}}) {
              push @acl, "$k:$v";
          }
          $href->{sprintf("%0$len.0f", $i+1)."_Perm_ACL"} = join ", ", @acl;
      }
      
      if($jdata->{data}{$qal}[$i]{additional}{time}) {
          $href->{sprintf("%0$len.0f", $i+1)."_Time_modified"} = FmtDateTime ($jdata->{data}{$qal}[$i]{additional}{time}{mtime});
          $href->{sprintf("%0$len.0f", $i+1)."_Time_changed"}  = FmtDateTime ($jdata->{data}{$qal}[$i]{additional}{time}{ctime});
          $href->{sprintf("%0$len.0f", $i+1)."_Time_accessed"} = FmtDateTime ($jdata->{data}{$qal}[$i]{additional}{time}{atime});
          $href->{sprintf("%0$len.0f", $i+1)."_Time_created"}  = FmtDateTime ($jdata->{data}{$qal}[$i]{additional}{time}{crtime});
      }
      
      if($jdata->{data}{$qal}[$i]{additional}{owner}) {
          $href->{sprintf("%0$len.0f", $i+1)."_Owner_GID"}   = $jdata->{data}{$qal}[$i]{additional}{owner}{gid};
          $href->{sprintf("%0$len.0f", $i+1)."_Owner_User"}  = $jdata->{data}{$qal}[$i]{additional}{owner}{user};
          $href->{sprintf("%0$len.0f", $i+1)."_Owner_Group"} = $jdata->{data}{$qal}[$i]{additional}{owner}{group};
          $href->{sprintf("%0$len.0f", $i+1)."_Owner_UID"}   = $jdata->{data}{$qal}[$i]{additional}{owner}{uid};
      }
      
      if($adds) {
          $href->{sprintf("%0$len.0f", $i+1)."__----------------------"} = "--------------------------------------------------------------------";
      }
  }
    
  $href->{EntriesTotalNum} = $total;
   
return;
}

#############################################################################################
#                                File Station File Download parse
#############################################################################################
sub _parseDownload { 
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $jdata = $paref->{jdata};
  my $param = $paref->{param};
  my $head  = $param->{httpheader};
  
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};
  my $idx   = $hash->{OPIDX};
  
  my $obj   = (split "=", $data{$type}{$name}{sendqueue}{entries}{$idx}{params})[1];
  
  Log3 ($name, 5, "$name - Header returned:\n".$head);
  
  if($head =~ /404\sNot\sFound/xms) {     
      Log3 ($name, 2, qq{$name - Object $obj not found for download});
      return 9002;                                                        # return Errorcode
  }
  
  my $err;
  my $sp   = q{};
  my $dest = $data{$type}{$name}{sendqueue}{entries}{$idx}{dest};

  open my $fh, '>', $dest or do { $err = qq{Can't open file "$dest": $!};
                                  Log3($name, 2, "$name - $err");
                                  return 417;                            # return Errorcode
                                };       

  if(!$err) {     
      binmode $fh;
      print   $fh $jdata;
      close   $fh;
  }
  
  Log3 ($name, 3, qq{$name - Object downloaded to "$dest"});
   
return;
}

#############################################################################################
#                                File Station File Upload parse
#############################################################################################
sub _parseUpload { 
  my $paref = shift;
  my $hash  = $paref->{hash};
  my $jdata = $paref->{jdata};
  my $href  = $paref->{href};                             # Hash Referenz für Ergebnisreadings
  my $param = $paref->{param};
  my $head  = $param->{httpheader};
  
  my $name  = $hash->{NAME};
  my $idx   = $hash->{OPIDX};
  
  Log3 ($name, 5, "$name - Header returned:\n".$head);
  
  my $skip = jboolmap ($jdata->{data}{blSkip});
  my $file = $jdata->{data}{file};
  
  $href->{FileWriteSkipped} = $skip;
  $href->{PID}              = $jdata->{data}{pid};
  $href->{Progress}         = $jdata->{data}{progress};
  $href->{RemoteFile}       = $file;
  
  if($skip eq "false") {
      Log3 ($name, 3, qq{$name - Object uploaded to "$file"});
  } else {
      Log3 ($name, 3, qq{$name - Object upload skipped due to "$file" already exists});
  }
   
return;
}

#############################################################################################
#                                     check SID
#############################################################################################
sub checkSID { 
  my $name = shift;
  my $hash = $defs{$name};
  my $type = $hash->{TYPE};
  
  # SID holen bzw. login
  my $subref = \&execOp;
  
  if(!$hash->{HELPER}{SID}) {
      Log3  ($name, 3, "$name - no session ID found - get new one");
      login ($hash, $data{$type}{$name}{fileapi}, $subref, $name, $splitstr);
      return;
  }
   
return execOp($name);
}

#############################################################################################
#                            zu sendende URL ins Log schreiben
#############################################################################################
sub logUrl { 
  my $name = shift;
  my $url  = shift;
  my $hash = $defs{$name};
  my $sid  = $hash->{HELPER}{SID};
  
  if(AttrVal($name, "showPassInLog", 0)) {
      Log3($name, 4, "$name - Call-Out: $url");
  } 
  else {
      $url =~ s/$sid/<secret>/x;
      Log3($name, 4, "$name - Call-Out: $url");
  }
   
return;
}

#############################################################################################
#             erstelle einen Part für POST multipart/form-data 
#
#             $seq:  first - den ersten CRLF imBody nicht schreiben wegen HttpUtils Problem: 
#                            https://forum.fhem.de/index.php/topic,115156.0.html
#                    last  - Ergänzung des letzten Boundary
#
#############################################################################################
sub addBodyPart { 
  my $bound = shift;                                   # Boundary String
  my $cdisp = shift;
  my $val   = shift;
  my $seq   = shift // "";                             # Sequence: first, last
  
  my $part;
  
  $part .= "\r\n"                 if($seq ne "first");
  $part .= "--".$bound;
  $part .= "\r\n";
  $part .= $cdisp;
  $part .= "\r\n";
  $part .= "\r\n";
  $part .= $val;
  $part .= "\r\n--".$bound."--  " if($seq eq "last");
   
return $part;
}

#############################################################################################
#                       File::Find Auswertungsfunktion 
#     $found:  Hash Referenz für file : dir Paare
#############################################################################################
sub wanted {  
  my $file =  $File::Find::name;
  my $dir  =  $File::Find::dir;
  $dir     =~ s/^\.//x;
  $dir     =~ s/\/$//x;

  if(-f $file && -r $file) {
      $found->{"$file"} = "$dir";
  }
  
return;
}

1;

=pod
=item summary    Module to integrate Synology File Station
=item summary_DE Modul zur Integration der Synology File Station

=begin html

<a name="SSFile"></a>
<h3>SSFile</h3>
<ul>

</ul>

=end html
=begin html_DE

<a name="SSFile"></a>
<h3>SSFile</h3>
<ul>

    Mit diesem Modul erfolgt die Integration der Synology File Station in FHEM. 
    Das Modul SSFile basiert auf Funktionen der Synology File Station API. <br><br> 
    
    Die Verbindung zum Synology Server erfolgt über eine Session ID nach erfolgreichem Login. Anforderungen/Abfragen des Servers 
    werden intern in einer Queue gespeichert und sequentiell abgearbeitet. Steht der Server temporär nicht zur Verfügung, 
    werden die gespeicherten Abfragen abgearbeitet sobald die Verbindung zum Server wieder verfügbar ist. <br><br>    
    
    <b>Vorbereitung </b> <br><br>
    
    <ul>    
    Als Grundvoraussetzung muss das <b>Synology File Station Package</b> auf der Diskstation installiert sein. <br>    
    Die Zugangsdaten des verwendeten Users werden später über ein Set <b>credentials</b> Kommando dem angelegten Device 
    zugewiesen.
    <br><br>
        
    Weiterhin müssen diverse Perl-Module installiert sein: <br><br>
    
    <table>
    <colgroup> <col width=35%> <col width=65%> </colgroup>
    <tr><td>JSON                </td><td>                                   </td></tr>
    <tr><td>Data::Dumper        </td><td>                                   </td></tr>
    <tr><td>MIME::Base64        </td><td>                                   </td></tr>
    <tr><td>Time::HiRes         </td><td>                                   </td></tr>
    <tr><td>File::Find          </td><td>                                   </td></tr>
    <tr><td>Encode              </td><td>                                   </td></tr>
    <tr><td>POSIX               </td><td>                                   </td></tr>
    <tr><td>HttpUtils           </td><td>(FHEM-Modul)                       </td></tr>
    </table>
    
    <br><br>    
    </ul>

<a name="SSFiledefine"></a>
<b>Definition</b>
  <ul>
  <br>    
    Die Definition erfolgt mit: <br><br>
    <ul>
      <b><code>define &lt;Name&gt; SSFile &lt;ServerAddr&gt; [&lt;Port&gt;] [&lt;Protocol&gt;] </code></b> <br><br>
    </ul>
    
    Die Parameter beschreiben im Einzelnen:
    <br>
    <br>    
    
    <table>
    <colgroup> <col width=10%> <col width=90%> </colgroup>
    <tr><td><b>Name</b>           </td><td>der Name des neuen Devices in FHEM                                                  </td></tr>
    <tr><td><b>ServerAddr</b>     </td><td>die IP-Addresse der Synology DS. <b>Hinweis:</b> Wird der DNS-Name statt IP-Adresse verwendet, sollte das Attribut dnsServer im global Device gesetzt werden ! </td></tr>
    <tr><td><b>Port</b>           </td><td>optional - Port der Synology DS (default: 5000).                                    </td></tr>
    <tr><td><b>Protocol</b>       </td><td>optional - Protokoll zur Kommunikation mit der DS, http oder https (default: http). </td></tr>
    </table>

    <br><br>

    <b>Beispiele:</b>
     <pre>
      <code>define SynBackup SSFile 192.168.2.10 </code>
      <code>define SynBackup SSFile 192.168.2.10 5001 https </code>
      # erstellt ein SSFile-Device mit Standardport (5000/http) bzw. https mit Port 5001
     </pre>
     
    Nach der Definition eines Devices steht nur der set-Befehl <a href="#credentials">credentials</a> zur Verfügung.
    Mit diesem Befehl werden zunächst die Zugangsparameter dem Device bekannt gemacht. <br><br>

    </ul>
  
<a name="SSFileset"></a>
<b>Set </b>

<ul>
  <br>
  
  <ul>
  <a name="credentials"></a>
  <li><b> credentials &lt;User&gt; &lt;Passwort&gt; </b> <br>
  
  Speichert die Zugangsdaten. <br>
  
  </li><br>
  </ul> 
  
  <ul>
  <a name="Download"></a>
  <li><b> Download  "&lt;File&gt;[,&lt;File&gt;,...]" | "&lt;Ordner&gt;[,&lt;Ordner&gt;,...]" [&lt;args&gt;]</b> <br>
  
  Überträgt das(die) angegebene(n) File(s) oder Ordner von der Synology Diskstation zur Destination. 
  Ist ein Ordner angegeben, wird er bzw. der Inhalt im Zip-Format komprimiert in einer Datei gespeichert. 
  Ohne weitere Angaben wird das Quellobjekt im FHEM Root-Verzeichnis (üblicherweise /opt/fhem), abhängig von der Einstellung des 
  globalen Attributs <b>modpath</b>, mit identischem Namen gespeichert. <br><br>
  
  Optional kann angegeben werden: 
  <br> 
  
  <ul>
   <table>
   <colgroup> <col width=7%> <col width=93%> </colgroup>
     <tr><td><b>dest=</b>  </td><td><b>&lt;Filename&gt;</b>: das Objekt wird mit neuem Namen im default Pfad gespeichert            </td></tr>
     <tr><td>              </td><td><b>&lt;Pfad/Filename&gt;</b>: das Objekt wird mit neuem Namen im angegebenen Pfad gespeichert   </td></tr>
     <tr><td>              </td><td><b>&lt;Pfad/&gt;</b>: das Objekt wird mit ursprünglichen Namen im angegebenen Pfad gespeichert. <b>Wichtig:</b> der Pfad muß mit einem "/" enden.   </td></tr>
   </table>
  </ul>
  <br>
  
  Alle angegebenen Objekte sind insgesamt in <b>"</b> einzuschließen. <br><br>
  
  <b>Beispiele: </b> <br>
  set &lt;Name&gt; Download "/backup/Carport-20200625-1147065130.jpg"                             <br>
  set &lt;Name&gt; Download "/backup/Carport-20200625-1147065130.jpg" dest=carport.jpg            <br>
  set &lt;Name&gt; Download "/backup/Carport-20200625-1147065130.jpg" dest=./log/carport.jpg      <br>
  set &lt;Name&gt; Download "/backup/Carport-20200625-1147065130.jpg" dest=./log/                 <br>
  set &lt;Name&gt; Download "/Temp/Anträge 2020,/backup/Carport-20200625-1147065130.jpg"          <br>
  set &lt;Name&gt; Download "/backup/Carport-20200625-1147065130.jpg,/Temp/card.txt" dest=/opt/   <br>
  </li><br>
  </ul>
  
  <ul>
  <a name="listQueue"></a>
  <li><b> listQueue </b> <br>
  
  Zeigt alle Einträge in der Sendequeue. Die Queue ist normalerweise nur kurz gefüllt, kann aber im Problemfall 
  dauerhaft Einträge enthalten. Dadurch kann ein bei einer Abrufaufgabe aufgetretener Fehler ermittelt und zugeordnet
  werden. <br> 
  
  </li><br>
  </ul>
  
  <ul>
  <a name="logout"></a>
  <li><b> logout </b> <br>
  
  Der User wird ausgeloggt und die Session mit beendet. <br> 
  
  </li><br>
  </ul> 
  
  <ul>
  <a name="prepareDownload"></a>
  <li><b> prepareDownload "&lt;File&gt;[,&lt;File&gt;,...]" | "&lt;Ordner&gt;[,&lt;Ordner&gt;,...]" [&lt;args&gt;]</b> <br>
  
  Identisch zum "Download" Befehl. Der Download der Files/Ordner von der Synology Diskstation wird allerdings nicht sofort
  gestartet, sondern die Einträge nur in die Sendequeue gestellt. 
  Um die Übertragung zu starten, muß abschließend der Befehl <br><br>

  <ul>
    set &lt;Name&gt; startQueue 
  </ul>  
  <br>
  
  ausgeführt werden.  
  </li><br>
  </ul> 
  
  <ul>
  <a name="prepareUpload"></a>
  <li><b> prepareUpload "&lt;File&gt;[,&lt;File&gt;,...]" &lt;args&gt;</b> <br>
  
  Identisch zum "Upload" Befehl. Die Übertragung der Files zur Synology Diskstation wird allerdings nicht sofort
  gestartet, sondern die Einträge nur in die Sendequeue gestellt. 
  Um die Übertragung zu starten, muß abschließend der Befehl <br><br>

  <ul>
    set &lt;Name&gt; startQueue 
  </ul>  
  <br>
  
  ausgeführt werden.  
  </li><br>
  </ul>
  
  <ul>
  <a name="purgeQueue"></a>
  <li><b> purgeQueue </b> <br>
  
  Löscht Einträge in der Sendequeue. Es stehen verschiedene Optionen je nach Situation zur Verfügung: <br><br> 
   <ul>
    <table>
    <colgroup> <col width=15%> <col width=85%> </colgroup>
      <tr><td>-all-         </td><td>löscht alle in der Sendequeue vorhandenen Einträge </td></tr>
      <tr><td>-permError-   </td><td>löscht alle Einträge, die durch einen permanenten Fehler von der weiteren Verarbeitung ausgeschlossen sind </td></tr>
      <tr><td>&lt;Index&gt; </td><td>löscht einen eindeutigen Eintrag der Sendequeue </td></tr>
    </table>
   </ul>
   
  </li><br>
  </ul>
   
  <ul>
  <a name="startQueue"></a>
  <li><b> startQueue </b> <br>
  
  Die Abarbeitung der Einträge in der Sendequeue wird gestartet. Bei den meisten Befehlen wird die Abarbeitung der Sendequeue 
  implizit gestartet. <br>
  
  </li><br>
  </ul>

  <ul>
  <a name="Upload"></a>
  <li><b> Upload  "&lt;File&gt;[,&lt;File&gt;,...]" | "&lt;Ordner&gt;[,&lt;Ordner&gt;,...]" &lt;args&gt;</b> <br>
  
  Überträgt das(die) angegebene(n) lokalen File(s)/Ordner zur Synology Diskstation.  
  Im Argument <b>dest</b> ist das Zielverzeichnis auf der Synology Diskstation anzugeben. 
  Der Pfad der zu übertragenden lokalen Files/Ordner kann als absoluter oder relativer Pfad zum FHEM global 
  <b>modpath</b> angegeben werden. <br>
  In Ordnern werden die Inhalte inklusive Subordnern ausgelesen und zur Destination Struktur erhaltend übertragen. 
  Unterverzeichnisse werden per default in der Destination angelegt wenn sie nicht vorhanden sind. <br>  
  Alle angegebenen Objekte sind insgesamt in <b>"</b> einzuschließen. <br><br>
  
  Argumente: 
  <br>
  
  <ul>
   <table>
   <colgroup> <col width=7%> <col width=93%> </colgroup>
     <tr><td><b>dest=</b>  </td><td><b>&lt;Ordner&gt;</b>: das File im angegebenen Pfad gespeichert (der Pfad beginnnt mit einem shared Folder und endet ohne "/")                     </td></tr>
     <tr><td><b>ow=  </b>  </td><td>(optional) <b>true</b>: das File wird überschrieben wenn im Ziel-Pfad vorhanden (default), <b>false</b>: das File wird nicht überschrieben         </td></tr>
     <tr><td><b>cdir=</b>  </td><td>(optional) <b>true</b>: übergeordnete(n) Ordner erstellen, falls nicht vorhanden. (default), <b>false</b>: übergeordnete(n) Ordner nicht erstellen </td></tr>
   </table>
  </ul>
  <br>
  
  <b>Beispiele: </b> <br>
  set &lt;Name&gt; Upload "./text.txt" dest=/home/upload                                                               <br>
  set &lt;Name&gt; Upload "/opt/fhem/old data.txt" dest=/home/upload ow=false                                          <br>
  set &lt;Name&gt; Upload "./Archiv neu 2020.txt" dest=/home/upload                                                    <br>
  set &lt;Name&gt; Upload "./log" dest=/home/upload                                                                    <br>
  set &lt;Name&gt; Upload "/opt/fhem/fhem.pl,./www/images/PlotToChat.png,./log/fhem-2020-10-41.log" dest=/home/upload  <br>
  </li><br>
  </ul>
   
 </ul>

<a name="SSFileget"></a>
<b>Get</b>
 <ul>
  <br>
 
  <ul>
  <a name="apiInfo"></a>
  <li><b> apiInfo </b> <br>
  Ruft die API Informationen der Synology File Station ab und öffnet ein Popup mit diesen Informationen.
  </li><br>
  </ul>
  
  <ul>
  <a name="fileInfo"></a>
  <li><b> fileInfo "&lt;File&gt;[,&lt;File&gt;,...]" </b> <br>
  Listet Informationen von einer oder mehreren Dateien der Synology Diskstation getrennt durch ein Komma "," auf. 
  Alle Objekte sind insgesamt in <b>"</b> einzuschließen.
  <br><br>
  
  <b>Beispiele: </b> <br>
  get &lt;Name&gt; fileInfo "/ApplicationBackup/export.csv,/ApplicationBackup/export_2020_09_25.csv" <br>
  </li><br>
  <br>
  </ul>
  
  <ul>
  <a name="folderList"></a>
  <li><b> folderList [&lt;args&gt;] </b> <br>
  Listet alle freigegebenen Ordner oder Dateien in einem angegebenen Ordner der Synology Diskstation auf und erstellt 
  detaillierte Dateiinformationen. 
  Ohne Argument werden alle freigegebenen Wurzel-Ordner aufgelistet. Ein Ordnerpfad und zusätzliche 
  <b>Optionen</b> können angegeben werden. <br><br>
  
  <table>
    <colgroup> <col width=10%> <col width=90%> </colgroup>
    <tr><td><b>sort_direction=</b> </td><td> <b>asc</b>: aufsteigend sortieren, <b>desc</b>: absteigend sortieren                                                                        </td></tr>
    <tr><td><b>onlywritable=</b>   </td><td> <b>true</b>: listet beschreibbarer freigegebener Ordner, <b>false</b>: auflisten beschreibbarer und schreibgeschützter freigegebener Ordner </td></tr>
    <tr><td><b>limit=</b>          </td><td> <b>Integer</b>: Anzahl der angeforderten Dateien. 0 - alle Dateien in einem bestimmten Ordner zeigen (default).                             </td></tr>
    <tr><td><b>pattern=</b>        </td><td> Muster zum Filtern von anzuzeigenden Dateien bzw. Dateiendungen. Mehrere Muster können durch "," getrennt angegeben werden.                 </td></tr>
    <tr><td><b>filetype=</b>       </td><td> <b>file</b>: nur Dateien listen, <b>dir</b>: nur Ordner listen, <b>all</b>: Dateien und Ordner listen                                       </td></tr>
  </table>
  <br>
  
  Objekte mit Leerzeichen im Namen sind in <b>"</b> einzuschließen. <br><br>
  
  <b>Beispiele: </b> <br>
  get &lt;Name&gt; folderList /home <br>
  get &lt;Name&gt; folderList "/home/30_Haus & Bau" <br>
  get &lt;Name&gt; folderList "/home/30_Haus & Bau" filetype=file limit=2 <br>
  get &lt;Name&gt; folderList "/home/30_Haus & Bau" sort_direction=desc <br>
  get &lt;Name&gt; folderList /home/Lyrik pattern=doc,txt
  </li><br>
  <br>
  </ul>
  
  <ul>
  <a name="storedCredentials"></a>
  <li><b> storedCredentials </b> <br>
  
  Zeigt die gespeicherten User/Passwort Kombination. 
  </li><br>  
  
  <br>
  </ul>
  
  <ul>
  <a name="versionNotes"></a>
  <li><b> versionNotes </b> <br>
  
  Zeigt Informationen und Hilfen zum Modul.
  </li><br>  
  
  <br>
  </ul>
 </ul>  
  
<a name="SSFileattr"></a>
<b>Attribute</b>
 <br><br>
 <ul>

  <ul>  
  <a name="interval"></a>
  <li><b>interval &lt;Sekunden&gt;</b> <br> 
  
    Automatisches Abrufintervall der Informationen in Sekunden. Ist "0" agegeben, wird kein automatischer Datenabruf 
    ausgeführt. (default) <br>
    Sollen z.B. jede Stunde Informationen abgerufen werden, wird das Attribut wie folgt gesetzt: <br><br>
    
    <ul>
      attr &lt;Name&gt; interval 3600  <br>
    </ul>    
    
  </li><br>
  </ul>  
  
  <ul>  
  <a name="loginRetries"></a>
  <li><b>loginRetries</b> <br> 
  
    Anzahl der Versuche für das inititiale User login. <br>
    (default: 3)
    
  </li><br>
  </ul>
  
  <ul>  
  <a name="showPassInLog"></a>
  <li><b>showPassInLog</b> <br> 
  
    Wenn "1" wird das Passwort bzw. die SID im Log angezeigt. <br>
    (default: 0)
    
  </li><br>
  </ul>

  <ul>  
  <a name="timeout"></a>
  <li><b>timeout  &lt;Sekunden&gt;</b> <br> 
  
    Timeout für den Datenabruf in Sekunden. <br>
    (default: 20)
    
  </li><br>
  </ul> 
  
 </ul>
 
</ul>

=end html_DE

=for :application/json;q=META.json 57_SSFile.pm
{
  "abstract": "Integration of the Synology File Station.",
  "x_lang": {
    "de": {
      "abstract": "Integration der Synology File Station."
    }
  },
  "keywords": [
    "Synology",
    "Download",
    "Upload",
    "Backup",
    "Filestransfer",
    "File Station"
  ],
  "version": "v1.1.1",
  "release_status": "testing",
  "author": [
    "Heiko Maaz <heiko.maaz@t-online.de>"
  ],
  "x_fhem_maintainer": [
    "DS_Starter"
  ],
  "x_fhem_maintainer_github": [
    "nasseeder1"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.014,
        "POSIX": 0,
        "JSON": 4.020,
        "Data::Dumper": 0,
        "MIME::Base64": 0,
        "Time::HiRes": 0,
        "HttpUtils": 0,
        "Encode": 0,
        "FHEM::SynoModules::API": 0,
        "FHEM::SynoModules::SMUtils": 0,
        "FHEM::SynoModules::ErrCodes": 0,
        "GPUtils": 0,
        "File::Find": 0
      },
      "recommends": {
        "FHEM::Meta": 0
      },
      "suggests": {
      }
    }
  },
  "resources": {
    "x_wiki": {
      "web": "https://wiki.fhem.de/wiki/SSFile_-_Integration_der_Synology_File_Station",
      "title": "SSFile - Integration der Synology File Station"
    },
    "repository": {
      "x_dev": {
        "type": "svn",
        "url": "https://svn.fhem.de/trac/browser/trunk/fhem/contrib/DS_Starter",
        "web": "https://svn.fhem.de/trac/browser/trunk/fhem/contrib/DS_Starter/50_SSFile.pm",
        "x_branch": "dev",
        "x_filepath": "fhem/contrib/",
        "x_raw": "https://svn.fhem.de/fhem/trunk/fhem/contrib/DS_Starter/50_SSFile.pm"
      }      
    }
  }
}
=end :application/json;q=META.json

=cut
