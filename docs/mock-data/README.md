# AWS mock data for aws.nvim

This directory contains fake AWS CLI output for testing aws.nvim without an AWS account or network access. The examples are based on the fixture in `spec/aws/lambda_workflow_spec.lua`, with additional representative JSON for other services.

Use this data to verify browsing, filtering, download, upload, invoke, and log-following behavior against a deterministic local source. Do not use it as production AWS data.
