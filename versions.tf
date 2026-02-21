# Terraform and Provider Version Constraints

terraform {
  required_version = ">= 1.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "azurerm" {
  features {}
}
