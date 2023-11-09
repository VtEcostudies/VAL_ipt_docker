#!/bin/bash -x

filename=val_ipt_latest.tar.gz
filepath=/home/ubuntu/val_ipt/aws_backups/
echo $filepath$filename

aws s3 cp $filepath$filename s3://ipt.backups/$filename
