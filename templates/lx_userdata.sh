#!/bin/bash

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

instance_os="${instance_os}"
instance_type="${instance_type}"

exec &> "${userdata_log}"

build_slug="${build_slug}"
error_signal_file="${error_signal_file}"
temp_dir="${temp_dir}"
export AWS_REGION="${aws_region}"
debug_mode="${debug}"

echo "------------------------------- $instance_os $instance_type ---------------------"

debug-2s3() {
  ## With as few dependencies as possible, immediately upload the debug and log
  ## files to S3. Calling this multiple times will simply overwrite the
  ## previously uploaded logs.
  local msg="$1"

  debug_file="$temp_dir/debug.log"
  echo "$msg" >> "$debug_file"
  aws s3 cp "$debug_file" "s3://$build_slug/$${instance_os}$${instance_type}/" > /dev/null 2>&1 || true
  aws s3 cp "${userdata_log}" "s3://$build_slug/$${instance_os}$${instance_type}/" > /dev/null 2>&1 || true
}

check-metadata-availability() {
  local metadata_loopback_az="http://169.254.169.254/latest/meta-data/placement/availability-zone"
  try_cmd 50 curl -sSL $metadata_loopback_az
}

start_postfix() {
  if [[ "$instance_os" == rhel6* ]] ; then
    try_cmd 10 yum install postfix
    try_cmd 50 service postfix start
  fi
}

enable-yum-repo() {
  if [[ "$instance_os" == rhel6* ]] ; then
    try_cmd 10 yum-config-manager --enable rhui-REGION-rhel-server-releases-optional
    try_cmd 10 yum -y update
  fi
}

write-tfi() {
  local msg=""
  local result=""

  while [[ "$#" -gt 0 ]]
  do
    case $1 in
      --result)
        result="$2"
        shift
        ;;
      *)
        msg="$msg $1"
        ;;
    esac
    shift
  done
  msg="$(echo -e "$msg" | sed -e 's/^[[:space:]]*//')"

  if [ "$result" = "" ]; then
    out_result=""
  elif [ "$result" = "0" ]; then
    out_result=": Succeeded"
  else
    out_result=": Failed"
  fi

  echo "$(date +%F_%T): $msg $out_result"

  if [ "$debug_mode" != "0" ] ; then
    debug-2s3 "$(date +%F_%T): $msg $out_result"
  fi
}

try_cmd() {
  local n=0
  local try=$1
  local result=1
  local command_output="None"
  [[ $# -le 1 ]] && {
    echo "Usage $0 <number_of_attempts> <Command>"
    exit $result
  }

  shift 1

  if [ "$try" -gt 1 ]; then
    write-tfi "Will try $try time(s) :: $@"
  fi

  if [[ "$SHELLOPTS" == *":errexit:"* ]]; then
    set +e
    local ERREXIT=1
  fi

  until [[ $n -ge $try ]]; do
    sleep $n
    command_output=`"$@" 2>&1`
    result=$?
    write-tfi "$@ :: code $result :: output: $command_output" --result $result
    if [[ $result -eq 0 ]]; then
      break
    else
      ((n++))
      write-tfi "Attempt $n, command failed :: $@"
      fail_snippet="Command ($@) failed :: code $result :: output: $command_output"
    fi
  done

  if [[ "$ERREXIT" == "1" ]]; then
    set -e
  fi

  return $result
}  # ----------  end of function try_cmd  ----------

open-ssh() {
  # open firewall on rhel 6/7 and ubuntu, move ssh to non-standard

  local new_ssh_port="${ssh_port}"

  if [ -f /etc/redhat-release ]; then
    ## CentOS / RedHat

    # allow ssh to be on non-standard port (SEL-enforced rule)
    try_cmd 1 setenforce 0

    # open firewall (iptables for rhel/centos 6, firewalld for 7

    if systemctl status firewalld &> /dev/null ; then
      try_cmd 1 firewall-cmd --zone=public --permanent --add-port="$new_ssh_port"/tcp
      try_cmd 1 firewall-cmd --reload
    else
      try_cmd 1 iptables -A INPUT -p tcp --dport "$new_ssh_port" -j ACCEPT #open port $new_ssh_port
      try_cmd 1 service iptables save
      try_cmd 1 service iptables restart
    fi

    try_cmd 1 sed -i -e "5iPort $new_ssh_port" /etc/ssh/sshd_config
    try_cmd 1 sed -i -e 's/Port 22/#Port 22/g' /etc/ssh/sshd_config
    try_cmd 1 service sshd restart

  else
    ## Not CentOS / RedHat (i.e., Ubuntu)

    # open firewall/put ssh on a new port
    try_cmd 1 ufw allow "$new_ssh_port"/tcp
    try_cmd 1 sed -i "s/Port 22/Port $new_ssh_port/g" /etc/ssh/sshd_config
    try_cmd 1 service ssh restart
  fi
}

publish-artifacts() {
  # stage, zip, upload artifacts to s3

  # create a directory with all the build artifacts
  artifact_base="$temp_dir/terrafirm"
  artifact_dir="$artifact_base/build-artifacts"
  mkdir -p "$artifact_dir/scap_output"
  mkdir -p "$artifact_dir/cloud/scripts"
  mkdir -p "$artifact_dir/audit"
  mkdir -p "$artifact_dir/messages"
  cp -R /var/log/watchmaker/ "$artifact_dir" || true
  cp -R /root/scap/output/* "$artifact_dir/scap_output/" || true
  cp -R /var/log/cloud*log "$artifact_dir/cloud/" || true
  cp -R /var/lib/cloud/instance/scripts/* "$artifact_dir/cloud/scripts/" || true
  cp -R /var/log/audit/*log "$artifact_dir/audit/" || true
  cp -R /var/log/messages "$artifact_dir/messages/" || true

  # move logs to s3
  artifact_dest="s3://$build_slug/$${instance_os}$${instance_type}"
  cp "${userdata_log}" "$artifact_dir"
  aws s3 cp "$artifact_dir" "$artifact_dest" --recursive || true
  write-tfi "Uploaded logs to $artifact_dest" --result $?

  # creates compressed archive to upload to s3
  zip_file="$artifact_base/$${build_slug//\//-}-$${instance_os}$${instance_type}.tgz"
  cd "$artifact_dir"
  tar -cvzf "$zip_file" .
  aws s3 cp "$zip_file" "s3://$build_slug/" || true
  write-tfi "Uploaded artifact zip to S3" --result $?
}

finally() {
  # time it took to install
  end=$(date +%s)
  runtime=$((end-start))
  write-tfi "WAM install took $runtime seconds."
  
  printf "%s\n" "$${userdata_status[@]}" > "${userdata_status_file}"

  open-ssh
  publish-artifacts

  exit "$${userdata_status[0]}"
}

catch() {
  local exit_code="$${1:-1}"
  write-tfi "$0: line $2: exiting with status $1"
  userdata_status=("$exit_code" "Userdata install error: $fail_snippet")
  finally
}

install-watchmaker() {
  # install watchmaker from source

  GIT_REPO="${git_repo}"
  GIT_REF="${git_ref}"

  PYPI_URL="${pypi_url}"

  # Install pip
  try_cmd 2 python3 -m ensurepip --upgrade --default-pip

  # Upgrade pip and setuptools
  try_cmd 2 python3 -m pip install --index-url="$PYPI_URL" --upgrade pip setuptools
  try_cmd 1 python3 -m pip --version

  # Install boto3
  try_cmd 1 python3 -m pip install --index-url="$PYPI_URL" --upgrade boto3

  # Clone watchmaker
  try_cmd 1 git clone "$GIT_REPO" --recursive
  cd watchmaker
  if [ -n "$GIT_REF" ] ; then
    # decide whether to switch to pull request or a branch
    num_re='^[0-9]+$'
    if [[ "$GIT_REF" =~ $num_re ]] ; then
      try_cmd 1 git fetch origin pull/"$GIT_REF"/head:pr-"$GIT_REF"
      try_cmd 1 git checkout pr-"$GIT_REF"
    else
      try_cmd 1 git checkout "$GIT_REF"
    fi
  fi

  # Update submodule refs
  try_cmd 1 git submodule update --init --recursive

  # Install watchmaker
  try_cmd 1 python3 -m pip install --upgrade --index-url "$PYPI_URL" --editable .
  try_cmd 1 watchmaker --version
}

# everything below this is the TRY

# start time of install
start=$(date +%s)

# declare an array to hold the status (number and message)
userdata_status=(0 "Passed")

%{ if instance_type == "builder" }

# BUILDER INPUT -------------------------------------------
export DEBIAN_FRONTEND=noninteractive
virtualenv_base=/opt/wam
virtualenv_path="$virtualenv_base/venv"
virtualenv_activate_script="$virtualenv_path/bin/activate"
# ---------------------------------------------------------

handle_builder_exit() {
  if [ "$1" != "0" ] ; then
    echo "For more information on the error, see the lx_builder/userdata.log file." > "$temp_dir/error.log"
    echo "$0: line $2: exiting with status $1" >> "$temp_dir/error.log"

    artifact_dest="s3://$build_slug/$error_signal_file"
    write-tfi "Signaling error at $artifact_dest"
    aws s3 cp "$temp_dir/error.log" "$artifact_dest" || true
    write-tfi "Upload error signal" --result $?

    catch "$@"

  else
    finally "$@"
  fi
}

try_cmd 1 apt-get -y update && apt-get -y install awscli

# to resolve the issue with "sudo: unable to resolve host"
# https://forums.aws.amazon.com/message.jspa?messageID=495274
host_ip=$(hostname)
if [[ $host_ip =~ ^[a-z]*-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}$ ]]; then
  # hostname is ip
  ip=$${host_ip#*-}
  ip=$${ip//-/.}
  try_cmd 1 echo "$ip $host_ip" >> /etc/hosts
else
  try_cmd 1 echo "127.0.1.1 $host_ip" >> /etc/hosts
fi

try_cmd 1 echo "ARRAY <ignore> devices=/dev/sda" >> /etc/mdadm/mdadm.conf

try_cmd 1 UCF_FORCE_CONFFNEW=1 \
  apt-get -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confnew" \
  upgrade

# install prerequisites
try_cmd 1 apt-get -y install \
  python-virtualenv \
  apt-transport-https \
  ca-certificates \
  curl \
  software-properties-common \
  python3 \
  python3-venv \
  python3-pip \
  git

# setup error trap to go to signal_error function
set -e
trap 'handle_builder_exit $? $LINENO' EXIT

# start the firewall
try_cmd 1 ufw enable
try_cmd 1 ufw allow ssh

# virtualenv
mkdir -p "$virtualenv_path"
cd "$virtualenv_base"
try_cmd 1 virtualenv --python=/usr/bin/python3 "$virtualenv_path"
source "$virtualenv_activate_script"

install-watchmaker

# Launch docker and build watchmaker
export DOCKER_SLUG="${docker_slug}"
try_cmd 1 chmod +x ci/prep_docker.sh && ci/prep_docker.sh

# ----------  begin of wam deploy  -------------------------------------------

source .gravitybee/gravitybee-environs.sh

if [ -n "$GB_ENV_STAGING_DIR" ] ; then

  # only using "latest" so versioned copy is just wasted space
  rm -rf "$GB_ENV_STAGING_DIR"/0*
  write-tfi "Remove versioned standalone (keeping 'latest')" --result $?

  artifact_dest="s3://$build_slug/${release_prefix}/"
  try_cmd 1 aws s3 cp "$GB_ENV_STAGING_DIR" "$artifact_dest" --recursive

fi

# ----------  end of wam deploy  ---------------------------------------------

%{ else }

# setup error trap to go to catch function


check-metadata-availability

set -e
trap 'catch $? $LINENO' EXIT

if [ "$instance_type" == "sa" ]; then
  standalone_location="s3://$build_slug/${executable}"
  error_location="s3://$build_slug/$error_signal_file"
  sleep_time=20
  nonexistent_code="nonexistent"
  no_error_code="0"

  write-tfi "Looking for standalone executable at $standalone_location"

  #block until executable exists, an error, or timeout
  while true; do

    # aws s3 ls $standalone_location ==> exit 1, if it doesn't exist!

    # find out what's happening with the builder
    exists=$(aws s3 ls "$standalone_location" || echo "$nonexistent_code")
    error=$(aws s3 ls "$error_location" || echo "$no_error_code")

    if [ "$error" != "0" ]; then
      # error signaled by the builder
      write-tfi "Error signaled by the builder"
      write-tfi "Error file found at $error_location"
      catch 1 "$LINENO"
      break
    else
      # no builder errors signaled
      if [ "$exists" = "$nonexistent_code"  ]; then
        # standalone does not exist
        write-tfi "The standalone executable was not found. Trying again in $sleep_time s..."
        sleep "$sleep_time"
      else
        # it exists!
        write-tfi "The standalone executable was found!"
        break
      fi
    fi

  done

  standalone_dest=/home/maintuser
  try_cmd 1 aws s3 cp "$standalone_location" "$standalone_dest/watchmaker"
  chmod +x "$standalone_dest/watchmaker"

  try_cmd 1 "$standalone_dest"/watchmaker ${common_args} ${lx_args}

else
  # test install from source
  enable-yum-repo

  # Install git
  try_cmd 5 yum -y install git

  install-watchmaker

  start_postfix

  # Run watchmaker
  try_cmd 1 watchmaker ${common_args} ${lx_args}

  # ----------  end of wam install  ----------
fi
%{ endif }

finally
