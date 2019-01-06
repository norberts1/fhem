# fhem
This repository is a placeholder for updated modules used in FHEM context.

The reason for this repository is to have a FHEM related (pre/early) update for that modules
used in heater-data interception.

Finaly released modules you should get with FHEM-update.
See www.FHEM.de for more details.

## Description

The perl-modul **89_HEATRONIC.pm** is part of the FHEM-project.

After installation of **fhem** you can use that modul, but there aren't any new features included.

To get and test new features, the pre-release in this repository will help you.

## Installation

- get the pre-release fhem-modul *89_HEATRONIC.pm* from this repository.

- copy the current modul:
 
    **cd /opt/fhem/FHEM**
  
    **sudo cp 89_HEATRONIC.pm 89_HEATRONIC.pm.origin**

- copy the new modul:

    **sudo cp ~/89_HEATRONIC.pm /opt/fhem/FHEM/89_HEATRONIC.pm**

- create the new documenation:

    **cd /opt/fhem/**

    **sudo /usr/bin/perl ./contrib/commandref_join.pl**

    **sudo /usr/bin/perl ./contrib/commandref_static.pl**

- restart the fhem-server with the web-interface button *restart*.

## Changelog
### 2019-01-05
- Updated *Cxyz-Controller* handling for decoding messages.

- Added new functions to send commands to *Cxyz-Controller* and heater-bus
 (only available with *ht_pitiny-* or *ht_piduino-* adapters).

- Added new attribute 'ControllerName'.

- New MsgID handling for: 26,30,615,797,798 and Powerswitch Modul.

- Added new logitems: *hcx_Tflow_desired* and *hcx_pump*, where x:= 1 ... 2.

- Correction of *sol_yield_last_hour*, value devided by 10.

- corrected *attr Betriebsart eventMap*

- Html-documentation updated.

### 2016-05-14
- Added *Cxyz-Controller* handling for decoding messages.

- corrected names in doc: *hc1_Trequested* and *hc1_mode_requested*.


