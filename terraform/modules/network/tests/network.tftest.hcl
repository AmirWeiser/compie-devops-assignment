# Offline unit test: mock_provider replaces the AWS provider, so nothing is called or created.

mock_provider "aws" {}

# Mocked ids/arns are only known at plan time for explicitly overridden resources.
# Distinct values per resource also stop a cross-reference check from passing by accident.

override_resource {
  target          = aws_subnet.public
  override_during = plan
  values          = { id = "subnet-public" }
}

override_resource {
  target          = aws_internet_gateway.main
  override_during = plan
  values          = { id = "igw-main" }
}

override_resource {
  target          = aws_nat_gateway.main
  override_during = plan
  values          = { id = "nat-main" }
}

override_resource {
  target          = aws_route_table.public
  override_during = plan
  values          = { id = "rtb-public" }
}

override_resource {
  target          = aws_route_table.private
  override_during = plan
  values          = { id = "rtb-private" }
}

override_resource {
  target          = aws_vpc_endpoint.dynamodb
  override_during = plan
  values          = { id = "vpce-dynamodb" }
}

override_data {
  target = data.aws_availability_zones.available
  values = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
}

variables {
  name     = "compie-app-dev"
  region   = "us-east-1"
  vpc_cidr = "10.0.0.0/16"
}

run "two_azs_public_and_private" {
  command = plan

  assert {
    condition     = aws_subnet.public[*].cidr_block == ["10.0.0.0/24", "10.0.1.0/24"]
    error_message = "Public subnets must be 10.0.0.0/24 and 10.0.1.0/24."
  }

  assert {
    condition     = aws_subnet.private[*].cidr_block == ["10.0.10.0/24", "10.0.11.0/24"]
    error_message = "Private subnets must be 10.0.10.0/24 and 10.0.11.0/24."
  }

  assert {
    condition     = aws_subnet.public[*].availability_zone == ["us-east-1a", "us-east-1b"] && aws_subnet.private[*].availability_zone == ["us-east-1a", "us-east-1b"]
    error_message = "One public and one private subnet per AZ, in the first two AZs."
  }

  assert {
    condition     = aws_vpc.main.tags.Name == "compie-app-dev" && aws_subnet.private[0].tags.Name == "compie-app-dev-private-us-east-1a"
    error_message = "Naming convention changed."
  }
}

run "private_egress_via_single_nat_and_endpoints" {
  command = plan

  assert {
    condition     = aws_nat_gateway.main.subnet_id == aws_subnet.public[0].id
    error_message = "The single NAT must sit in the first public subnet."
  }

  assert {
    condition     = one(aws_route_table.private.route).nat_gateway_id == aws_nat_gateway.main.id
    error_message = "Private subnets must route 0.0.0.0/0 through the NAT."
  }

  assert {
    condition     = one(aws_route_table.public.route).gateway_id == aws_internet_gateway.main.id
    error_message = "Public subnets must route 0.0.0.0/0 through the internet gateway."
  }

  assert {
    condition = (
      aws_vpc_endpoint.dynamodb.service_name == "com.amazonaws.us-east-1.dynamodb" &&
      aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3" &&
      aws_vpc_endpoint.dynamodb.route_table_ids == toset([aws_route_table.private.id])
    )
    error_message = "S3 and DynamoDB gateway endpoints must be attached to the private route table."
  }

  assert {
    condition     = output.dynamodb_endpoint_id == aws_vpc_endpoint.dynamodb.id
    error_message = "dynamodb_endpoint_id must be the DynamoDB gateway endpoint (used in the IAM aws:SourceVpce condition)."
  }
}

run "rejects_a_single_az" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}
