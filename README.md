# kernel-automation
A personal script for automating gentoo kernel building

<img width="839" height="707" alt="Screenshot_20260121_154033" src="https://github.com/user-attachments/assets/4ee71b22-8c81-4d77-8971-ccc73e6627da" />


- There is a config file where lotsa stuff can be set like gpu vendor(s)
- If the kernel config has initramfs enabled, then it will generate one with a choice of dracut or ugrd (preferred)
- If the kenrel config has module signing enabled, and NVIDIA is being used, then it will strip and sign the modules using supplied keys
- Has an option for enabling LLVM (clang) for the kernel building, and also for NVIDIA modules
- Has a choice of 3 bootloaders. I've only tested systemd-boot though, since that's what I use. But limine and GRUB should work fine

Make sure the correct kernel is selected using `eselect kernel list` and 'eselect kernel set <>' before running. And make sure you drop your custom config into `/usr/src/linux`. Also make sure the kernel config is complete, otherwise it will take you though every option and it won't be fun.

Make sure to edit the config.env file, and set it up for your system.
