# Hypervisor is always 'both' now - the base image is neutral and PreSeal-Agents.ps1
# decides at run time. Kept in the answer file only so older files still parse.
$Hypervisor          = 'both'
$AdditionalAdminUser = 'chadmin'
$TimeZone            = 'Arabian Standard Time'
$RunWindowsUpdate    = $True
$SnapshotPostWU      = $True
$Unattended          = $true
$PauseOnFail         = $false
$VirtioDrive         = ''
$OptimizeDisk        = $False
$DeepOptimize        = $True
$SnapshotPause       = $True
$StageAcronis        = $True
$StageBitdefender    = $True
$StageWazuh          = $True
$StageGlpi           = $True
$StageOsquery        = $True
$StageMetadata       = $True
$StageSite24x7       = $True
$StageZabbix         = $True
$StageDiagTools      = $True
$CloudStackPwEnabled = $True
$NtfyTopic           = 'https://ntfy.sh/9890122212'
$SSHPubKeys          = @('ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDT4Bi+YX8sx4ikrOz0J0k9CjQYMXvLid94Qy001cXMoPLrr3D/PSa3yANwuxKnQTNau1697WsAv3mYTUnYFItTbZXMjtIACMJ4uKOmCtHZnP2VFgWRV8jTxjw6mKUrNJceu9n4tBRY1X6zj3ZEXbeJ6r5aSiWKzQQrjkvVRLxeXqyPABc59jmp6MAO8cB3q+AA9E+qOMFj3awu1BdAGUUfFFPmB8k6KVxBqEsRHO2mtnKpswofujGeBFX6La6M/cVXf7ZmlUfn+4cmQuphe94fqxmT49jliFQ8l3Cc2zD/GRJHYzNhiIyQAbhtKEsD6kbynTGNcq0/59BjpehAvgez','ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSMLjQxi/2e/MTTyuzD34SA+94GP1+Eyv3PjAXqSMhQy3MdWwZCrnrP+W7FON6ilIDhdI42usXmMhTr0eJQYsTwVdwMZE9OtF4SniauuN7YvJkG9O3W6YclGr0U8xqo4QH48ZQYntB37nP5PUIOgFKkVyH3T7MR2Dp8VZo0n6oa7hgMjIJOVcmC8zhEm0+4/JJSL60gaGA2/251jSELOlAVTalKyuOipZYjnNOY4TqU9owCRPJNGd9e3rP4QOO0p5xjtsFSNDMqacpCSYiIc26y2GNjOqthvWGa4/O84QmMqbtG053VrmNQZGSgmGw+4b9ajC/9Bh8dU0XSEN9ijqc1U86zNXL10GhhAV+H2R3V5wLPbFK3/NAPOi4sqZ1eXq6denlr6Ap2/cAvUT089v5L1CkoXaZY2QCLQleHH3jPRKzvzB+7g7R7VIDXVX977qleExzi48XinzV+W5+dZyHbAK+9iOf5orJGOMWWxj1LKYltPUQeY19B+H4fRDfhDmw7+94oqFxnDPjMaSdcTAosoQ4EdKwqBmtdWhDAaxsIHa1ynkmUo0IwbosDJayjl/GqHeiyAwWWG/7CKwJXTef4ZYETwIWdXobZElzh9/kGrKgoalzT5K5f6sBM/IBciPfhSz8PaOiWc0RwLEkqX8JtzzllgBZItuIKWpSWl4TUw==')
