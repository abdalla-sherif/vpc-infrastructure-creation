# VPC Setup Using AWS CLI

## Description
This project demonstrates how to create and configure an Amazon VPC environment using the AWS CLI. The setup includes public and private subnets, route tables, and an Internet Gateway attached to the VPC.

## Architecture Overview
The VPC architecture consists of:
- 1 VPC created via AWS CLI  
- 2 Public Subnets  
- 2 Private Subnets  
- 1 Public Route Table associated with the two public subnets  
- 1 Private Route Table associated with the two private subnets  
- 1 Internet Gateway (IGW) created and attached to the VPC  

## Steps Performed
1. Created the VPC using AWS CLI.  
2. Created two public subnets within the VPC.  
3. Created two private subnets within the VPC.  
4. Created a public route table and associated it with the two public subnets.  
5. Created a private route table and associated it with the two private subnets.  
6. Created an Internet Gateway and attached it to the VPC.  
7. Added a route in the public route table pointing to the Internet Gateway to allow outbound internet access for public subnets.
