// Additional Terraform script to set up CICD functionality with Azure Devops
// Current workflow:
//  - Require that SP created in main-azure are Enterprise Applications
//  - Role definitions of SPs are updated to allow access to the storage backend
//  - Variable groups created to allow secrets generated to be passed through into CICD scripts
data "azuredevops_project" "project_name" {
  name = var.azure_devops_project_name
}

data "azurerm_subscription" "current" {
}

data "azuredevops_project" "project" {
  name = var.azure_devops_project_name
}

data "azuredevops_git_repository" "repo" {
  project_id = data.azuredevops_project.project.project_id
  name       = var.azure_devops_repo_name
}

// Required that service principals have access to storage backend. Assign permissions
resource "azurerm_role_definition" "role_definition" {
  name               = "{{cookiecutter.project_name}}-role-definition"
  scope              = data.azurerm_subscription.current.id

  permissions {
    actions     = ["Microsoft.Storage/storageAccounts/listkeys/action"]
  }

}

data "azuread_service_principal" "staging_service_principal" {
  application_id = module.azure_create_sp.staging_service_principal_application_id
}

resource "azurerm_role_assignment" "staging_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.role_definition.role_definition_resource_id
  principal_id       = data.azuread_service_principal.staging_service_principal.object_id
}

data "azuread_service_principal" "prod_service_principal" {
  application_id = module.azure_create_sp.prod_service_principal_application_id
}

resource "azurerm_role_assignment" "prod_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.role_definition.role_definition_resource_id
  principal_id       = data.azuread_service_principal.prod_service_principal.object_id
}

// Create variable group to be used by Azure DevOps Pipelines
resource "azuredevops_variable_group" "cicd_vg" {
  project_id   = data.azuredevops_project.project.project_id
  name         = "CICD Variable Group"
  description  = "Variable group for CICD pipelines"
  allow_access = true

  variable {
    name  = "STAGING_DATABRICKS_HOST"
    value = "{{cookiecutter.databricks_staging_workspace_host}}"
  }

  variable {
    name         = "STAGING_AZURE_SP_APPLICATION_ID"
    secret_value = module.azure_create_sp.staging_service_principal_application_id
    is_secret    = true
  }

  variable {
    name          = "STAGING_AZURE_SP_CLIENT_SECRET"
    secret_value  = module.azure_create_sp.staging_service_principal_client_secret
    is_secret     = true
  }

  variable  {
    # NOTE: assumes staging and prod Databricks workspaces are under the same Azure tenant
    name  = "STAGING_AZURE_SP_TENANT_ID"
    value = var.azure_tenant_id
  }

  variable {
    name  = "PROD_DATABRICKS_HOST"
    value = "{{cookiecutter.databricks_prod_workspace_host}}"
  }

  variable {
    name         = "PROD_AZURE_SP_APPLICATION_ID"
    secret_value = module.azure_create_sp.prod_service_principal_application_id
    is_secret    = true
  }

  variable {
    name          = "PROD_AZURE_SP_CLIENT_SECRET"
    secret_value  = module.azure_create_sp.prod_service_principal_client_secret
    is_secret     = true
  }

  variable  {
    name  = "PROD_AZURE_SP_TENANT_ID"
    // NOTE: assumes staging and prod Databricks workspaces are under the same Azure tenant
    value = var.azure_tenant_id
  }

  variable  {
    name  = "ARM_ACCESS_KEY"
    value = var.arm_access_key
    is_secret     = true
  }

  variable  {
    name  = "ARM_SUBSCRIPTION_ID"
    value = data.azurerm_subscription.current.subscription_id
  }

}

resource "azuredevops_build_definition" "testing-ci" {
  project_id = data.azuredevops_project.project.project_id
  name       = "testing_ci"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = data.azuredevops_git_repository.repo.id
    branch_name = data.azuredevops_git_repository.repo.default_branch
    yml_path    = "./.azure/devops-pipelines/testing-ci.yml"
  }

  variable_groups = [azuredevops_variable_group.cicd_vg.id]
}

resource "azuredevops_build_definition" "terraform-cicd" {
  project_id = data.azuredevops_project.project.project_id
  name       = "terraform_cicd"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = data.azuredevops_git_repository.repo.id
    branch_name = data.azuredevops_git_repository.repo.default_branch
    yml_path    = "./.azure/devops-pipelines/terraform-cicd.yml"
  }

  variable_groups = [azuredevops_variable_group.cicd_vg.id]
}

// PR validation is not enabled by default in Azure DevOps (see https://learn.microsoft.com/en-us/azure/devops/pipelines/repos/azure-repos-git?view=azure-devops&tabs=yaml#pr-triggers).
// In our CICD workflow we trigger our testing CI and terraform CI pipelines on PR to {{cookiecutter.default_branch}}.
// To automate setup, we use Terraform to configure a Build validation policy for PRs to the default branch (for more info, https://learn.microsoft.com/en-us/azure/devops/repos/git/branch-policies?view=azure-devops&tabs=browser#build-validation)
resource "azuredevops_branch_policy_build_validation" "testing-ci-build-validation" {
  project_id = data.azuredevops_project.project.project_id

  enabled  = true
  blocking = true

  settings {
    display_name        = "Testing CI build validation policy"
    build_definition_id = azuredevops_build_definition.testing-ci.id
    valid_duration      = 720

    scope {
      repository_id  = data.azuredevops_git_repository.repo.id
      repository_ref = data.azuredevops_git_repository.repo.default_branch
      match_type     = "Exact"
    }

    scope {
      match_type     = "DefaultBranch"
    }
  }
}

resource "azuredevops_branch_policy_build_validation" "terraform-cicd-build-validation" {
  project_id = data.azuredevops_project.project.project_id

  enabled  = true
  blocking = true

  settings {
    display_name        = "Terraform CICD build validation policy"
    build_definition_id = azuredevops_build_definition.terraform-cicd.id
    valid_duration      = 720

    scope {
      repository_id  = data.azuredevops_git_repository.repo.id
      repository_ref = data.azuredevops_git_repository.repo.default_branch
      match_type     = "Exact"
    }

    scope {
      match_type     = "DefaultBranch"
    }
  }
}