# Setting AWS Credentials
# Enter a set of accesskey and secretkey with the correct permissions
# Region: us-west-2 is Oregon
Set-AWSCredential -AccessKey 'AccessKey' -SecretKey 'SecretKey' -StoreAs Admin
Initialize-AWSDefaultConfiguration -ProfileName Admin -Region us-west-2

# Create a new VPC with CIDR 10.0.0.0/24
$vpcNew = New-EC2VPC -CidrBlock '10.0.0.0/24' 
$vpcNewId = $vpcNew.VpcId
# Make a name tag for this vpc for easier recognization
New-EC2Tag -Resource $vpcNewId -Tag @{Key='Name'; Value='NewVPC'}

# Returns the default routing table to be used later
$defaultRouteTable = Get-EC2RouteTable -Filter @{ Name = "vpc-id"; Value = $vpcNewId}

# Create a new internet gateway
$igwNew = New-EC2InternetGateway
$igwNewId = $igwNew.InternetGatewayId
New-EC2Tag -Resource $igwNewId -Tag @{Key='Name'; Value='NewIGW'}

# Attach internet gateway to vpc created above
Add-EC2InternetGateway -InternetGatewayId $igwNewId -VpcId $vpcNewId

# Create new Route Table
$routeTableNew = New-EC2RouteTable -VpcId $vpcNewId
$routeTableNewId = $routeTableNew.RouteTableId

# Create new Route to access internet
$routeToInternet = New-EC2Route -RouteTableId $routeTableNewId -GatewayId $igwNewId -DestinationCidrBlock '0.0.0.0/0'

# Create 2 public subnets for the VPC
# Each of these subnets will have 59 IP addresses available
$publicSub1 = New-EC2Subnet -VpcId $vpcNewId -CidrBlock '10.0.0.0/26' -AvailabilityZone 'us-west-2a'
$publicSubId1 = $publicSub1.SubnetId
New-EC2Tag -Resource $publicSubId1 -Tag @{Key='Name'; Value='Public SN1'}
$publicSub2 = New-EC2Subnet -VpcId $vpcNewId -CidrBlock '10.0.0.64/26' -AvailabilityZone 'us-west-2b'
$publicSubId2 = $publicSub2.SubnetId
New-EC2Tag -Resource $publicSubId2 -Tag @{Key='Name'; Value='Public SN2'}

# Register the two public subnets with the route table created above
Register-EC2RouteTable -RouteTableId $routeTableNewId -SubnetId $publicSubId1
Register-EC2RouteTable -RouteTableId $routeTableNewId -SubnetId $publicSubId2

# Create 2 private subnets for the VPC
# Each of these subnets will have 59 IP addresses available
# These 2 subnets do not need to be associated with any route table. 
# Without explicit association, they will use the main route table created with the VPC, which is private
$privateSub1 = New-EC2Subnet -VpcId $vpcNewId -CidrBlock '10.0.0.128/26' -AvailabilityZone 'us-west-2a'
$privateSubId1 = $privateSub1.SubnetId
New-EC2Tag -Resource $privateSubId1 -Tag @{Key='Name'; Value='Private SN1'}
$privateSub2 = New-EC2Subnet -VpcId $vpcNewId -CidrBlock '10.0.0.192/26' -AvailabilityZone 'us-west-2b'
$privateSubId2 = $privateSub2.SubnetId
New-EC2Tag -Resource $privateSubId2 -Tag @{Key='Name'; Value='Private SN2'}

# Create necessary security groups
# Create a SG for NAT instances and set up the ingress rules
$natSGId = New-EC2SecurityGroup -GroupName NATSG -Description 'Used by NAT instances' -VpcId $vpcNewId
Grant-EC2SecurityGroupIngress -GroupId $natSGId -IpPermission @{IpProtocol = 'tcp'; FromPort = 80; ToPort = 80; IpRanges = @("0.0.0.0/0")} 
# Following inbound rule allows SSH access into the instance using this SG from all IP, limit IpRanges value for higher security 
Grant-EC2SecurityGroupIngress -GroupId $natSGId -IpPermission @{IpProtocol = 'tcp'; FromPort = 22; ToPort = 22; IpRanges = @("0.0.0.0/0")}

# Create a SG for Elastic Load Balancer that is the entry point for the instances in the private subnets
$albSGId = New-EC2SecurityGroup -GroupName ELB -Description 'Used by ELB' -VpcId $vpcNewId
Grant-EC2SecurityGroupIngress -GroupId $albSGId -IpPermission @{IpProtocol = 'tcp'; FromPort = 80; ToPort = 80; IpRanges = @("0.0.0.0/0")}

# Create a SG for private instances 
# This SG will only allow incoming HTTP traffic from the ELB
$privateEC2Id = New-EC2SecurityGroup -GroupName PrivateEC2 -Description 'Used by instances in private subnets' -VpcId $vpcNewId
# Create a Object for UserIdGroupPair
$albIdGroupPair = New-Object Amazon.EC2.Model.UserIdGroupPair 
$albIdGroupPair.GroupId = $albSGId
Grant-EC2SecurityGroupIngress -GroupId $privateEC2Id -IpPermission @{IpProtocol = 'tcp'; FromPort = 80; ToPort = 80; UserIdGroupPairs = $albIdGroupPair}
Grant-EC2SecurityGroupIngress -GroupId $privateEC2Id -IpPermission @{IpProtocol = 'tcp'; FromPort = 22; ToPort = 22; IpRanges = @("0.0.0.0/0")}

# Launch a NAT instance in a public subnet
$natInstance = New-EC2Instance -ImageId ami-034ee9d6627a58739 -SubnetId $publicSubId1 -MinCount 1 -MaxCount 1 -KeyName windows -SecurityGroupId $natSGId -InstanceType t2.micro
$natInstanceId = ($natInstance.Instances).InstanceId
Edit-EC2InstanceAttribute -InstanceId $natInstanceId -SourceDestCheck $false
# Wait 30 seconds here to make sure the NAT instance is in 'running' state before proceeding
Start-Sleep -s 30
New-EC2Route -RouteTableId $defaultRouteTable.RouteTableId -InstanceId $natInstanceId -DestinationCidrBlock '0.0.0.0/0'

# Create a UserData script
$userDataString = @"
#!/bin/bash
sudo su
echo "hello this is web site in private-a" > /var/www/html/index.html
"@
$encodeData = [System.Text.Encoding]::UTF8.GetBytes($userDataString)
$userData = [System.Convert]::ToBase64String($encodeData) 

# Launch an instance in the private-a subnet and use the userdata script above
# Key is included in case debugging is needed
$privateInstance1 = New-EC2Instance -ImageId ami-034ee9d6627a58739 -SubnetId $privateSubId1 -MinCount 1 -MaxCount 1 -SecurityGroupId $privateEC2Id -InstanceType t2.micro -KeyName windows -UserData $userData
$privateInstanceId1 = ($privateInstance1.Instances).InstanceId
New-EC2Tag -Resource $privateInstanceId1 -Tag @{Key='Name'; Value='Private Instance A'}

# Create another script for a second instance
$userDataString2 = @"
#!/bin/bash
sudo su
echo "hello this is web site in private-b" > /var/www/html/index.html
"@
$encodeData2 = [System.Text.Encoding]::UTF8.GetBytes($userDataString2)
$userData2 = [System.Convert]::ToBase64String($encodeData2) 
$privateInstance2 = New-EC2Instance -ImageId ami-034ee9d6627a58739 -SubnetId $privateSubId2 -MinCount 1 -MaxCount 1 -SecurityGroupId $privateEC2Id -InstanceType t2.micro -KeyName windows -UserData $userData2
$privateInstanceId2 = ($privateInstance2.Instances).InstanceId
New-EC2Tag -Resource $privateInstanceId2 -Tag @{Key='Name'; Value='Private Instance B'}

# Create a Load Balancer
$newALB = New-ELB2LoadBalancer -Name 'Test' -Scheme internet-facing -Subnet @($publicSubId1,$publicSubId2) -SecurityGroup $albSGId
$newTargetGroup = New-ELB2TargetGroup -HealthCheckIntervalSecond 6 -HealthCheckPath '/index.html' -HealthCheckProtocol HTTP -HealthyThresholdCount 3 -Name 'Test' -Port 80 -VpcId $vpcNewId -HealthCheckPort 80 -HealthCheckTimeoutSecond 5 -Protocol HTTP
$newAction = New-Object Amazon.ElasticLoadBalancingV2.Model.Action
$newAction.TargetGroupArn = $newTargetGroup.TargetGroupArn
$newAction.Type = [Amazon.ElasticLoadBalancingV2.ActionTypeEnum]::Forward
$newHTTPLister = New-ELB2Listener -Port 80 -Protocol HTTP -LoadBalancerArn $newALB.LoadBalancerArn -DefaultAction $newAction

$targetDescription1 = New-Object Amazon.ElasticLoadBalancingV2.Model.TargetDescription
$targetDescription1.Id = $privateInstanceId1
$targetDescription1.Port = 80

$targetDescription2 = New-Object Amazon.ElasticLoadBalancingV2.Model.TargetDescription
$targetDescription2.Id = $privateInstanceId2
$targetDescription2.Port = 80

Start-Sleep -s 30
Register-ELB2Target -Target @($targetDescription1,$targetDescription2) -TargetGroupArn $newTargetGroup.TargetGroupArn

