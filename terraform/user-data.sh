#!/bin/bash

# Update the package list
sudo apt-get update -y

# Install Docker
sudo apt-get install -y docker.io

# Add the ubuntu user to the docker group to run Docker without sudo
sudo usermod -aG docker ubuntu

# Start Docker service
sudo service docker start

# Output confirmation messages
echo "Server setup completed!"
echo "Docker version:"
docker --version
