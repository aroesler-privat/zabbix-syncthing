# zabbix-syncthing

## About
It was about Christmas and I started to feel a little nerdy. So inside of me a wish was growing up: I wanted to have an overview over all the backup- and sync-processes I run during the day. So I installed Zabbix and started to play around with its extensions.
This is a Bash-script consuming (one says so, right?) the RestAPI of Syncthing. When installed in your Zabbix-scripts-directory and after deploying the Template you may see the following data per Syncthing-folder:
* device-last-seen (string): when was the remote device seen for the last time?
* last-folder-scan-time (string): when happened the last local scan of the folder?
* last-sync-time (string): when was a file synced for the last time?
* last-synced-file (string): guess what?!? ;-)

Furthermore a quite expensive /rest/db/status-call is done to catch values like:
* globalBytes, inSyncBytes, needBytes: amount of bytes in total, in sync and to by synced
* globalFiles, inSyncFiles, needFiles: amount of files in total, in sync and to be synced
* errors, pullErrors: amount of files that failed

## Install and Configure
1. download syncthing.sh and install it to you ExternalScripts-directory (zabbix_server.conf -> ExternalScripts)
2. make it executable: <code>chmod a+x syncthing.sh</code>
3. carefully read the output of <code>./syncthing.sh --help</code> - I hate to document and I did it just for you! ;-)

To access Syncthing you need an API-Key. You get it by looking in Syncthing's WebApp at Actions -> Advanced. By default the Syncthing-Server can be defined via commandline (--ip, --port, --apikey -> the template is intended to use this too). But there might be situations in which you don't want to have your API-Key stored on Zabbix. In these cases you may add one or many Syncthing-hosts by:
* opening syncthing.sh
* searching for the line <code>## Adding static syncthing-hosts</code>
* adding your host: <code>add_syncthing_host "INTERNALHOSTNAME" "IP" "PORT" "API Key"</code>
You may address such an host by using the <code>--host=INTERNALHOSTNAME</code>-parameter.

Now download the template (template_syncthing.xml) and add it to your Zabbix via Configuration -> Templates -> Import. In the template directly go to the Macros-menu (well hidden as sub-tab in the first tab) and either add your Syncthing-Server-details or create a new <code>--host</code>-macro and edit all the items to use it.

## Background
You will realize there are two applications setup: <code>general</code> and <code>folder-stats</code>. While the items listed under <code>general</code> are each calling the script and directly receiving data, the <code>folder-stats</code>-items are slighlty more complex. 

The REST-call needed to fetch those data is quite expensive (as the Syncthing-developers say). So I thought it makes sense to do it as seldom as possible. The script is called with extra-parameters to fetch the errors-key. During this call all the data-fields given as comma-seperated string with the <code>--status=</code>-parameter are filled with data via zabbix_sender.

## You want more?
When calling the script like <code>./syncthing.sh --api-key="mykey" --folder="myfolder" --status | jq</code> all the fields you may request are given. Feel free to change the template to fetch other values. 
