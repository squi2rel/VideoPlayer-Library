FROM ubuntu:latest
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk vlc
RUN mkdir -p /workspace
WORKDIR /workspace
