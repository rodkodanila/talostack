# 00-terraform

Создаёт в Proxmox VE три ВМ, загружающиеся с ISO Talos Linux, который уже лежит в хранилище Proxmox (Terraform его не скачивает). После `apply` ВМ стоят в maintenance-режиме Talos и ждут machine config.

ISO должен быть собран под платформу `nocloud` (например, в [Image Factory](https://factory.talos.dev): Cloud Server → Nocloud, с расширением `qemu-guest-agent`). Тогда Proxmox cloud-init диск отдаёт Talos hostname (имя ВМ) и сеть. Для ISO `metal` поставьте `talos_platform = "metal"`: cloud-init диска не будет, адреса только по DHCP.

## Диски и сети

- `vm_defaults.disks` — список дисков; подключаются по порядку как `scsi0`, `scsi1`, … (шина — `vm_defaults.disk_bus`). У каждого свой `size_gb` и `storage` (имя хранилища Proxmox), плюс `cache`, `discard`, `ssd`, `iothread`, `backup`. Первый диск — загрузочный. `nodes[*].disks` заменяет список целиком для одной ноды.
- `network.interfaces` — список сетевых карт, одинаковый для всех ВМ (`net0`, `net1`, …): bridge, VLAN, MTU, модель, queues, rate limit, gateway.
- `nodes[*].network_interfaces` — MAC и IPv4 по позиции соответствующей карты. Без `ipv4_address` карта получает адрес по DHCP.

## Вложенная виртуализация

ВМ рассчитаны на запуск своих ВМ (OpenStack Nova, KubeVirt): `vm_defaults.cpu_type = "host"` пробрасывает в гостя vmx/svm, а `vm_defaults.nested_virtualization = true` (по умолчанию) не даёт выбрать модель CPU без них. Со стороны Proxmox нужен включённый nested в KVM — на хосте:

```sh
cat /sys/module/kvm_intel/parameters/nested   # или kvm_amd; ожидается Y / 1
```

Если `N`/`0`: `echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-nested.conf` (для AMD — `kvm_amd`), затем перезагрузка хоста или `modprobe -r kvm_intel && modprobe kvm_intel` при остановленных ВМ. Внутри гостя после установки Talos проверка: `talosctl -n <ip> ls /dev/kvm`.

## Запуск

```sh
cp terraform.tfvars.example terraform.tfvars   # поправить под себя
export TF_VAR_proxmox_api_token='terraform@pve!talos=...'
terraform init
terraform apply
terraform output nodes
```

Права токена в Proxmox: `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Audit`, `Datastore.AllocateSpace`, `Datastore.Audit` на хранилищах дисков и ISO, `SDN.Use` на bridge.

В maintenance-режиме Talos не запускает расширения, поэтому guest agent заработает только после установки. Terraform не ждёт IP от агента (`vm_defaults.agent_wait_for_ipv4 = false`); в `nodes` до установки заполнен только `ipv4_static`. После установки `terraform refresh` подтянет `ipv4_agent`.

ВМ грузятся сначала с диска, потом с ISO: пока диск пуст, стартует ISO, после установки Talos — диск.

## Тесты

```sh
terraform test
```

Тесты гоняют `plan` на mock-провайдере и проверяют валидацию переменных; доступ к Proxmox не нужен.
