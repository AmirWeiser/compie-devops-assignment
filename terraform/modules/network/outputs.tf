output "vpc_id" {
  description = "VPC id"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet ids, one per AZ (ALB, NAT)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids, one per AZ (EC2 instances)"
  value       = aws_subnet.private[*].id
}

output "dynamodb_endpoint_id" {
  description = "Used in IAM conditions (aws:SourceVpce) to allow DynamoDB access only through this VPC"
  value       = aws_vpc_endpoint.dynamodb.id
}
