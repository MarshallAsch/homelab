# Infrastructure as Code

This is designed to provide a frictionless way to get all of my home services back up and running without needing to manually reconfigure everything. 

## Docker compose

This currently just contains the docker compose project that will start everything in a container. 

## Usage:

In order to make the [docker-compose.yml] file more generic, some portions of its configuration have been extracted into a `.env` file. A sample [env.template] file has been provided that includes the environment variables that need to be set. 

These environment variables (and the files for the volumes obviously) should be all that is needed to pick up all of the containers and drop them onto a new host. 

### Pre setup tasks:

1. Set up the `.env` file with all the needed variables. 
2. Update the `letsencrypt` subdomain variable with any different subdomains.
3. Update the `transmission` definition and get the correct openvpn file.
4. You probably want to turn off the `led` container as that is specific to my devices. 
5. Start the containers
6. edit the necessary configuration files once they are created
    - `letsencrypt` setup the reverse proxies

## Profiles

This docker compose file uses the concept of 'profiles' to allow different subsets of the containers to be started at a time.
Currently, there is only the default (no profile) and the `temp` profile that has been assigned to services that I am still testing or have not yet gotten running quite the way I want them yet.  

## Limitations

- The compose setup makes use of the macvlan networking mode which can have limitations imposed by the host machine supporting all the mac addresses in hardware, or from having too many mac addresses on one 802.11 interface. To avoid this make sure it is running with an Ethernet connection. 
- All of the containers are attached to the same macvlan network meaning that all the containers are accessible on the same LAN by default. That can be changed by implementing vlan or subnet isolation rules on the network. 
- Some of the containers still need to be manually configured prior to first use. 


## Next steps and things to add

Like all programming and IaC projects this is an ongoing learning adventure of what works best for me, what services I want to run and how it is configured. 
While there is a long list of other cool things that I would love to add to this project the following list includes the main ones:

- extract more of the configuration into environment variables
- Store some of the secrets as docker secrets rather than environment variables
- Move more of the containers over to the `linuxserver/*` images, I have been a big fan of their images
- Add other modules that can perform some of the configuration of the host, network, and DNS records that are needed
- Add automated backups to this project
- Add modules to configure other machines that I have running (ie the raspberry pi DNS failovers and jump hosts)