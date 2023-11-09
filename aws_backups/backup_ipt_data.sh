#!/bin/bash
dir=/home/ubuntu/val_ipt/aws_backups;
log=$dir/vce_ipt_backup.log;
now=`date '+%Y_%m_%d-%H_%M_%S'`;
inp=usr/ipt;
out=$dir/val_ipt_latest.tar.gz;
#cd $dir;
echo $now backup $inp to $out;
echo $now backup $inp to  $out >> $log;
tar -czf $out -C / $inp >> $log 2>&1;
