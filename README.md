curl -sL https://raw.githubusercontent.com/avotc/speedtest/refs/heads/main/speedtest.sh | bash -s -- https://sgp.proof.ovh.net/files/10Gb.dat 30

curl -sL https://raw.githubusercontent.com/avotc/speedtest/refs/heads/main/speedtest.sh -o speedtest.sh
chmod +x speedtest.sh
./speedtest.sh https://sgp.proof.ovh.net/files/10Gb.dat 30
