ip_list=(
172.31.30.107
172.31.16.77
172.31.23.244
172.31.30.22
172.31.25.198
172.31.26.103
172.31.25.168
172.31.17.138
172.31.27.229
172.31.19.94
172.31.16.31
172.31.30.191
172.31.20.122
172.31.26.220
172.31.24.157
172.31.17.61
)

for ip in ${ip_list[@]};
do
echo $ip
ssh -i ~/.ssh/junchao.pem -n -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@$ip "cd /home/ubuntu/install/resilientdb/go_client; git pull; "
done
