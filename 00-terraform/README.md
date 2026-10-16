# 00-terraform

Создаёт в Proxmox VE три ВМ, загружающиеся с ISO Talos Linux. ISO собирается в [Image Factory](https://factory.talos.dev) с нужными расширениями (по умолчанию `qemu-guest-agent`) и скачивается в Proxmox напрямую. После `apply` ВМ стоят в maintenance-режиме Talos и ждут machine config.

Платформа образа — `nocloud`: Proxmox cloud-init диск отдаёт Talos hostname (имя ВМ) и сеть. Если у ноды задан `ipv4_address`, адрес статический, иначе DHCP.

## Запуск

```sh
cp terraform.tfvars.example terraform.tfvars   # поправить под себя
export TF_VAR_proxmox_api_token='terraform@pve!talos=...'
terraform init
terraform apply
terraform output nodes
```

Минимальные права токена в Proxmox: `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Audit`, `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Datastore.Audit`, `Sys.Audit`, `Sys.Modify` (нужен для download-url), `SDN.Use`.

В maintenance-режиме Talos не запускает расширения, поэтому guest agent заработает только после установки. Terraform не ждёт IP от агента (`vm_defaults.agent_wait_for_ipv4 = false`), и в `nodes` у DHCP-нод до установки будет `unknown`: адрес смотрите в консоли ВМ или в DHCP-сервере. После установки `terraform refresh` подтянет IP от агента.

## Что дальше

`terraform output talos_installer_image` — образ для `machine.install.image` в machine config: при установке на диск Talos получит те же расширения, что и в ISO. ВМ грузятся с диска первым, поэтому после установки ISO больше не используется.

## Тесты

```sh
terraform test
```

Тесты гоняют `plan` на mock-провайдерах и проверяют валидацию переменных; доступ к Proxmox не нужен.
