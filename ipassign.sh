#!/bin/bash

OLD_IFS="$IFS"
IPADDR_P_REGEX="[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}"
IPADDR_REGEX="[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"

function get_next_addr() {
  if [ $(echo $1 | grep -E $IPADDR_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  target_p_str=$1
  target_str=${1%/*}

  IFS='/'
  set -- $target_p_str

  last_prefix=$2

  IFS=$OLD_IFS

  addr_int=$(to_i $target_str)
  last_addr_int=$(($addr_int + (1 << (32 - $last_prefix))))
  last_addr_str=$(to_s $last_addr_int)
  echo $last_addr_str
}

function get_last_addr() {
  if [ $(echo $1 | grep -E $IPADDR_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  target_p_str=$1
  target_str=${1%/*}

  IFS='/'
  set -- $target_p_str

  last_prefix=$2

  IFS=$OLD_IFS

  addr_int=$(to_i $target_str)
  last_addr_int=$(($addr_int + (1 << (32 - $last_prefix)) - 1))
  last_addr_str=$(to_s $last_addr_int)
  echo $last_addr_str
}

function to_s() {
  last=$1
  echo "$(($1 / (1 << 24))).$((($1 % (1 << 24)) / (1 << 16))).$((($1 % (1 << 16) / (1 << 8)))).$(($1 % (1 << 8)))"
}

function to_i() {
  if [ $(echo $1 | grep -E $IPADDR_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  IFS='.'
  set -- $1

  arr=($1 $2 $3 $4)

  IFS=$OLD_IFS

  echo "$(((1 << 24) * ${arr[0]} + (1 << 16) * ${arr[1]} + (1 << 8) * ${arr[2]} + 1 * ${arr[3]}))"
}

function show_gap() {
  local i

  if [ $(echo $1 | grep -E $IPADDR_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  from=$1
  from_int=$(to_i $from)

  if [ $(echo $2 | grep -E $IPADDR_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  to=$2
  to_int=$(to_i $to)

  gap=$(($to_int - $from_int))

  for i in $(seq 32 -1 1); do
    if [ $gap -ge $((1 << $i)) ]; then
      if [ $gap -eq $((1 << $i)) ]; then
        echo "$from/$((32 - $i)),unassigned"
        return 0
      else
        show_gap $(to_s $(($from_int + (1 << $i)))) $to
        return 0
      fi
    fi
  done
}

function check_gap() {
  local i

  if [ $(echo $1 | grep -E $IPADDR_P_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  check_cidr=$1
  user_assigned=($2)

  echo "check ${user_assigned[*]%,*} in $check_cidr" > /dev/stderr

  length=${#user_prefixes[*]}

  for i in $(seq 0 $(($length - 1))); do
    target_str=${user_assigned[$i]%,*}

    IFS='.'
    set -- $target_str

    target_arr=($1 $2 $3 $4)

    IFS=$OLD_IFS

    if [ $i -eq 0 ]; then
      if [ ${check_cidr%/*} != ${target_str%/*} ]; then
        show_gap ${check_cidr%/*} ${target_str%/*}
      fi

      echo ${user_assigned[$i]}
    else
      echo ${user_assigned[$i]}

      next_target_addr=$(get_next_addr $target_str)

      if [ $i -lt $(($length - 1)) ]; then
        if [ $next_target_addr != ${user_assigned[$(($i + 1))]%/*} ]; then
          show_gap $next_target_addr ${user_assigned[$(($i + 1))]%/*}
        fi
      fi
    fi

    if [ $i -eq $(($length - 1)) ]; then
      last_check_cidr=$(get_last_addr $check_cidr)
      last_target_addr=$(get_last_addr $target_str)
      next_target_addr=$(get_next_addr $target_str)

      if [ $last_target_addr != $last_check_cidr ]; then
        show_gap ${check_cidr%/*} $next_target_addr
      fi
    fi
  done
}

function get_cidrs() {
  local i
  local count

  if [ $(echo $1 | grep -E $IPADDR_P_REGEX | wc -l) -eq 0 ]; then
    return -1
  fi

  address=$1
  masklen=$2

  if [ ! \( $masklen -eq 24 \) ]; then
    return -1
  fi

  IFS='/'
  set -- $address

  network_address=$1
  prefix=$2

  if [ $prefix -gt $masklen ]; then
    return -1
  fi

  IFS='.'
  set -- $network_address

  oct1=$1
  oct2=$2
  oct3=$3

  IFS=$OLD_IFS

  count=$((1 << ($masklen - $prefix)))

  for i in `seq 0 $(($count - 1))`
  do
    cidr="$oct1.$oct2.$(($oct3 + $i)).0/$masklen"
    filename="$oct1.$oct2.$(($oct3 + $i)).0_$masklen"

    if [ -e $filename ]; then
      echo "fetching $filename skipped." > /dev/stderr
    else
      echo "get: $cidr" > /dev/stderr
      /usr/bin/whois -h whois.nic.ad.jp "$cidr/e" > $filename

      if [ $i -ne $(($count - 1)) ]; then
        sleep 10
      fi
    fi

    if [ $(cat $filename | grep -E 'b. \[Network Name\]' | /usr/bin/grep 'SUBA' | wc -l) -ne 0 ]; then
      if [ $(cat $filename | grep -E 'a. \[Network Number\]' | /usr/bin/grep $cidr | wc -l) -gt 0 ]; then
        user_prefixes=(
            $(/bin/cat $filename | \
            sed -n -e "/More Specific Info./,$(cat $filename | wc -l)p" | \
            grep -E $IPADDR_P_REGEX | \
            /usr/bin/awk '{print $3","$1}' | \
            /usr/bin/tr '\n' ' ' | \
            sed 's/\s$//g')
          )

        check_gap $cidr "${user_prefixes[*]}"
      fi
    else
      echo "$cidr is assigned."
    fi
  done
}

if [ $# -ne 1 ]; then
  exit -1
fi

get_cidrs $1 24
