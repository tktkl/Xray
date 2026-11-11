#!/usr/bin/env bash
# Examples only. Replace addresses, domains and links before running.
xray a reality 24443 --name reality-one --address YOUR_PUBLIC_IP
xray a reality 24444 --name reality-two --address YOUR_PUBLIC_IP
xray ob n001 direct
xray port n002 24445
xray new n001 ss
xray list
# Requires your own Cloudflare-controlled domain and configured credentials:
# xray cert setup --email admin@example.com
# xray a vws node.example.com auto /one
# xray a vgrpc node.example.com auto /two
