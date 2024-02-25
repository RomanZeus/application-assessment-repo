provider "aws" {
  region = "us-west-2"
}

variable "vpc_cidr" {}
variable "prefix" {}
variable "private_subnet_cidrs" {}
variable "public_subnet_cidrs" {}
variable "avail_zones" {}
variable "public_key_path" {}
variable "instance_type" {}

resource "aws_vpc" "ch_vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "${var.prefix}-vpc"
  }
}

resource "aws_subnet" "ch_private_subnet" {
  vpc_id = aws_vpc.ch_vpc.id
  cidr_block = element(var.private_subnet_cidrs, count.index)
  count = length(var.private_subnet_cidrs)
  availability_zone = element(var.avail_zones, count.index)
  tags = {
    Name = "private-subnet ${count.index + 1}"
  }
}

resource "aws_subnet" "ch_public_subnet" {
  vpc_id = aws_vpc.ch_vpc.id
  cidr_block = element(var.public_subnet_cidrs, count.index)
  count = length(var.public_subnet_cidrs)
  availability_zone = element(var.avail_zones, count.index)
  tags = {
    Name = "public-subnet ${count.index + 1}"
  }
}

resource "aws_internet_gateway" "ch_igw" {
  vpc_id = aws_vpc.ch_vpc.id
  tags = {
    Name = "${var.prefix}-igw"
  }
}

resource "aws_route_table" "ch_rtb" {
  vpc_id = aws_vpc.ch_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ch_igw.id
  }

  tags = {
    Name = "${var.prefix}-rtb"
  }
}

resource "aws_route_table_association" "ch_rtb_assc" {
  subnet_id = element(aws_subnet.ch_public_subnet[*].id, count.index)
  count = length(var.public_subnet_cidrs)
  route_table_id = aws_route_table.ch_rtb.id
}

# Data source to get the latest Ubuntu 20.04 LTS AMI for the free tier
data "aws_ami" "latest_ubuntu_image" {
  most_recent = true

  owners = ["099720109477"]  # Canonical's AWS account ID for Ubuntu

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }



# Create EC2 Key Pair
resource "aws_key_pair" "cloudhight" {
  key_name   = var.prefix
  public_key = file(var.public_key_path) # path to public key file
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data.sh")
}


resource "aws_default_security_group" "bastion_host_sg" {
  vpc_id = aws_vpc.ch_vpc.id
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    prefix_list_ids = []
  }

  tags = {
    Name = "bastion-sg"
  }
}

resource "aws_instance" "bastion_host" {
  ami = data.aws_ami.latest_ubuntu_image.id
  subnet_id = element(aws_subnet.ch_public_subnet[*].id, count.index)
  count = length(var.public_subnet_cidrs)
  vpc_security_group_ids = [aws_default_security_group.bastion_host_sg.id]
  instance_type = var.instance_type
  associate_public_ip_address = true
#   availability_zone = var.avail_zones
  key_name = aws_key_pair.cloudhight.key_name
  tags = {
    Name = "${var.prefix}-server"
  }
}

# Create Auto Scaling Group
resource "aws_launch_template" "my_launch_template" {
  name = "my-launch-template"
  vpc_security_group_ids = [aws_default_security_group.bastion_host_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 30
      volume_type = "gp2"
    }
  }


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.prefix}-instance"
    }
  }

  image_id        = data.aws_ami.latest_ubuntu_image.id
  instance_type   =  var.instance_type
  key_name        = aws_key_pair.cloudhight.key_name

  user_data = "${base64encode(data.template_file.user_data.rendered)}"

}

resource "aws_autoscaling_group" "my_asg" {
  desired_capacity     = 2
  min_size             = 2
  max_size             = 5
  vpc_zone_identifier = aws_subnet.ch_private_subnet[*].id

  launch_template {
    id      = aws_launch_template.my_launch_template.id
  }

  health_check_type          = "EC2"
  health_check_grace_period  = 300
  force_delete                = true
  wait_for_capacity_timeout  = "0"

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-asg-instance"
    propagate_at_launch = true
  }
}

# Create Application Load Balancer
resource "aws_lb" "my_alb" {
  name               = "ch-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_vpc.ch_vpc.default_security_group_id]

  enable_deletion_protection = false
  enable_http2              = true

  subnets = aws_subnet.ch_public_subnet[*].id

}

# Create IAM Role for EC2 instances
resource "aws_iam_role" "my_ec2_role" {
  name = "my-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach IAM policy to the IAM Role
resource "aws_iam_role_policy_attachment" "my_ec2_role_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess" 
  role       = aws_iam_role.my_ec2_role.name
}

# Attach IAM role to Auto Scaling Group
resource "aws_autoscaling_group" "attach_iam_role" {
  desired_capacity     = 2
  max_size             = 5
  min_size             = 2
  vpc_zone_identifier = aws_subnet.ch_private_subnet[*].id

  launch_template {
    id      = aws_launch_template.my_launch_template.id
    
  }

  health_check_type          = "EC2"
  health_check_grace_period  = 300
  force_delete                = true
  wait_for_capacity_timeout  = "0"

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-asg-instance"
    propagate_at_launch = true
  }

}

output "image_name" {
  value = data.aws_ami.latest_ubuntu_image.id
}

output "bastion_host_ip" {
  value = aws_instance.bastion_host[0].public_ip
}

data "aws_instances" "private_instances" {
  instance_tags = {
    Name = "${var.prefix}-asg-instance"
  }
}

output "private_instance_ips" {
  value = data.aws_instances.private_instances.id
}

output "auto_scaling_group_instance_ips" {
  value = aws_autoscaling_group.my_asg.instances[*].private_ip
}
