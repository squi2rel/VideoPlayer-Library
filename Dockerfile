FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk libvlc5 libvlccore9 vlc-plugin-base
CMD ["java", "-version"]
