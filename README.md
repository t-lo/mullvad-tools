# mullvad-tools

Collection of basic tools for use with the Mullvad VPN service https://mullvad.net.

Main purpose is to allow running a single command within an ephemeral Docker container and force all its traffic and DNS through the Mullvad VPN.
The container neatly separates VPN network and routing configuration from the host's.
It will get access to the host's local directory to read and write files and directories.
Inside the container, the command will be run as the host user (uid/gid) who started the container.
This prevents file access problems.

The tool aims to be (almost) as easy as running the command on the host itself, all while ensuring traffic only goes through the VPN.

The container can also do simple Host traffic tunneling through the VPN, though it's a bit hacky.

### Usage

* `mullist.sh` - List all known Mullvad peers by country and server name.
  * `mullist.sh <server>` - Lists basic properties (IP address, key, country, city, ...) of one peer.
* `mullcmd.sh <devicenum> -- <command> ...` - Run `<command>` in an ephemeral container connected to the VPN.
  The local directory (from where the command was run on the host) is mounted into the container and will be the working directory for `<command>`.
  The hosts's user and group IDs from which the container was started will be used to run the command.
  Any output in the host mount will therefore "belong" to the user who started the container.
  * E.g. `mullcmd.sh <devicenum> -- bash` - Runs an interactive shell in the container.
    You'll likely be an unprivileged user but you'll have password-less `sudo` access.
  * `mullcmd.sh help` - Prints detailed command help.
    The command supports a number of optional parameters, such as setting a custom peer and / or port.
* `mullcmd.sh <devicenum> tunnel` - Sets up a tunnel for routing host trafficthrough the VPN.
  See "Advanced Usage" below for a detailed description of tunnel mode.
  **NOTE** that this requires you to also run a `tunnel.sh` helper script (which the command will produce) as root on the host.

See below for advanced usage like host traffic tunneling through the VPN.

## Prerequisites and Set-Up

An account with Mullvad: https://mullvad.net/en/account.
We will need the account number later.
If the account isn't active, the VPN will not route traffic.

1. Fetch the tool scripts from the repo.
   For the purpose of this documentation we'll assume `mullvad-tools` will live in `/opt/mullvad-tools/`.
   ```bash
   mkdir -p /opt/mullvad-tools/
   cd /opt/mullvad-tools/
   ```
   Clone this repo 
   ```bash
   git clone https://github.com/t-lo/mullvad-tools.git .
   ```
   or download a [zip](archive/refs/heads/main.zip) and unpack.
   ```bash
   wget https://github.com/t-lo/mullvad-tools/archive/refs/heads/main.zip
   unzip -j main.zip
   rm main.zip
   ```
2. Build the Docker container locally.
   ```bash
   ./build.sh
   ```

### First-time set-up

We'll create an environment file with Mullvad account information, and fill it with predefined wireguard "devices".
A "device" simply is a private / public key combination.

1. Create the .env file from the template provided in the repo.
   ```bash
   cp env.example .env
   chmod 600 .env
   ```
2. Fill in your account number.
   Edit `.env` with your favourite editor and set
   ```
   account=""
   ```
   to your Mullvad account number.
3. Create private / public keys for wireguard devices.
   You can either do this manually or just run
   ```bash
   for i in 1 2 3 4 5; do
        tmpfile="$(mktemp)"
        echo "devices[$i,\"key\"]=\"$(wg genkey|tee ${tmpfile})\""
        echo "devices[$i,\"pub\"]=\"$(wg pubkey < "${tmpfile}")\""
        echo "devices[$i,\"port\"]=\"8080\""
        echo
        rm "${tmpfile}"
    done
    ```
    and copy+paste the output into the `.env` file.
    The above uses remote port 8080 by default (this can be changed on the command line later).
4. Optionally, edit the devices' peer settings at the bottom of the `.env` file if you want to use different default peers.
   Run
   ```
   ./mullist.sh
   ```
   to get a list of all peers.
   Use two comma-separated peers in order to set up a multihop VPN that uses different nodes for VPN traffic entry and exit.
5. Optionally, add `/opt/mullvad-tools` to your `PATH` so you can run `mullcmd.sh` and `mullist.sh` anywhere on the host.

### Adding commands / tools to the container

The stock container image aims to be as lean as possible.
For one-off cases, adding software via
```
./mullcmd.sh 1 -- bash
apk add ...
```
is a good enough pattern.
However, because of the container's ephemeral nature, everything will be reset when you exit.

You might find yourself in need of a tool in the container that you regularly use.
In that case, edit the `Dockerfile` (there's an `apk add ...` line there) and rebuild by running `build.sh` again.


### Update the tools

If you used `git clone` to install, updating is as simple as `git pull --rebase`.
Otherwise, download the new zip file and overwrite the contents of `/opt/mullvad-tools/` with the new versions.

## Advanced usage: Tunnel all host traffic

It is entirely possible to route all host traffic through the container and thus through the VPN - including DNS.
Note that this is not the main use case of `mullvad-tools` so it tends to be a bit hacky.

In this set-up, the VPN container will replace the host's default gateway.
All local networks known to the host will still be reachable directly, i.e. traffic will not be forced through the VPN.
However, as DNS is intercepted on the host, you might run into DNS resolve issues for local DNS addresses
as these will be unknown to Mullvad's DNS server.

You will need `sudo` or `root` access on the host for this.

To set things up:
1. Run
   ```bash
   ./mullcmd.sh 1 tunnel
   ```
   (Feel free to use a different device number).
   This will start the container in tunnel mode and create a helper script `tunnel.sh` in the host directory the container was started in.
2. Leave the container running, and in a separate terminal _on the host_ run the `tunnel.sh` helper script as root.
   ```bash
   sudo ./tunnel.sh
   ```
   The script will print what it's doing, and pause after the tunnel routes were set up.

You might experience transient DNS issues.

Check via https://mullvad.net/en/check on the host whether you're tunneling successfully.

To stop the tunneling:

1. Press `[RETURN]` in the terminal where `tunnel.sh` is running, to clean up host routes.
1. Press `[RETURN]` in the container to shut it down.

Once again you might experience transient DNS issues.

#### Routing details

1. On the host, we create a dedicated route to the VPN server's public IP via the host's original default gateway, so it won't be affected by the VPN catch-all routes.
2. Then, we create 2 routes into the container, using the docker-assigned container IP as gateway.
   These two network routes allow us to override the host's default route without changing / deleting it.
   The networks we route to are smaller than the default route (`/1` instead of `/0`) so they have routing priority.
   And both combined cover all network ranges, capturing all traffic.
   1. `0.0.0.0/1` and
   2. `128.0.0.0/1`
3. Lastly, we re-route DNS traffic to tcp and udp ports 53 to the VPN's DNS.

