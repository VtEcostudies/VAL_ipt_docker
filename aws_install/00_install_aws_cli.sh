curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt update && sudo apt install unzip
unzip awscliv2.zip
sudo ./aws/install
sudo rm awscliv2.zip
sudo rm -r ./aws
