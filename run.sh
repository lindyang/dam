#!/bin/bash


pwd_=$(cd `dirname $0`; pwd)


openresty=$(which openresty 2> /dev/null)
if [ -z $openresty ]; then
    echo "Can not find openresty"
    exit 1
fi

CONF=${ENV:-dev}.conf
openresty -p $pwd_/ -c conf/$CONF

