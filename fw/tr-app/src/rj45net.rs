// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The home network on the board's RJ45 socket (docs/DECISIONS.md, docs/HL2_SFP.md section 9): the network unit
//! (`tr_fabric::eth`, the network unit's register page, 100 Mbit/s), its PHY start-up, and DHCP and SNTP for the
//! station's clock (`tr_net::nettime`). The main loop makes one call per turn, [`Rj45Net::poll`], and what happened comes
//! out of [`Rj45Net::take_event`], one console line each.
//!
//! Board identity (docs/NET_ID.md): the chip's factory ID is read from the network page and gives the Ethernet address and
//! the network name (`tr_net::ident`), unless a stored address overrides it; see [`Rj45Net::identity`].
//!
//! The network loader, TCI and the remote side of the GUI are not part of this module yet, because the interface for them
//! is still to be agreed (docs/HL2_SFP.md section 10). They will share the same `MacRings`, handed out
//! through [`NetPort`], and when the register page layout (`hw/regmap/net.toml`) changes only the offsets in the driver
//! change.

use core::fmt;

use tr_fabric::eth::{Eth, Phy, PhyEvent};
use tr_net::ident::{self, Source};
use tr_net::nettime::{NetStore, NetTime, TimeState};
use tr_regs::RegisterSpace;

/// Our address when the chip's ID could not be read and nothing is stored. It is locally administered and the same on every
/// board (the address of the HL2 link ends in 01), so two boards with it on one network collide.
pub const FALLBACK_MAC: [u8; 6] = [0x02, 0x54, 0x52, 0x00, 0x00, 0x02];

/// Reads of the ID's "done" bit before the start-up goes on without it. The reader finishes about 150 us after the chip's
/// reset, long before the processor runs, and a read takes about 0.25 us, so this waits at most 1 ms.
const ID_WAIT_READS: u32 = 4_000;

/// Who this board is on the network.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Identity {
    /// The chip's factory ID; `None` if the bitstream has no reader or it read nothing.
    pub chip_id: Option<u64>,
    /// The Ethernet address in use.
    pub mac: [u8; 6],
    /// Where `mac` came from.
    pub source: Source,
    /// "tang-" and the last three bytes of the address; the name on the network is this plus ".local".
    pub name: [u8; 11],
}

impl Identity {
    /// Picks the address from a stored setting, the chip ID or the fallback, in that order (`tr_net::ident::choose`).
    pub fn new(chip_id: Option<u64>, mac_setting: Option<[u8; 6]>) -> Self {
        let (mac, source) = ident::choose(mac_setting, chip_id, FALLBACK_MAC);
        Identity { chip_id, mac, source, name: ident::host_name(mac) }
    }
}

/// The start-up lines about the identity: ID, address and where it came from, name.
impl fmt::Display for Identity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.chip_id {
            Some(id) => writeln!(f, "board: chip ID {id:016x}")?,
            None => writeln!(f, "board: chip ID not read")?,
        }
        let m = self.mac;
        write!(f, "board: MAC {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} ", m[0], m[1], m[2], m[3], m[4], m[5])?;
        match self.source {
            Source::Setting => writeln!(f, "(stored setting)")?,
            Source::Dna => writeln!(f, "(from the chip ID)")?,
            Source::Fallback => writeln!(f, "(WARNING: the fixed address every board has; two boards on one network collide)")?,
        }
        write!(f, "board: network name {}.local", core::str::from_utf8(&self.name).unwrap_or("tang"))
    }
}

/// The network services that will share the unit (loader, TCI, GUI): a service gets the frames the stack does not take.
/// This is a stub, since the interface is not fixed yet and nothing implements it.
pub trait NetPort {
    /// Offers a frame to this service; `false` means it is not for it.
    fn offer(&mut self, frame: &[u8]) -> bool;
}

/// Something the operator should see on the console.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rj45Event {
    /// The PHY start-up or the link changed.
    Phy(PhyEvent),
    /// The network unit does not answer with its identifier (a bitstream without it).
    NoUnit,
}

impl fmt::Display for Rj45Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Rj45Event::Phy(PhyEvent::Ready { id, known }) => {
                write!(f, "rj45: PHY {id:#010x}{} set to 100 Mbit/s full duplex", if known { " (RTL8211F)" } else { "" })
            }
            // The start-up repeats from the reset every second with the wait doubling, and only the first failure is told.
            Rj45Event::Phy(PhyEvent::NoPhy(id)) => match id {
                Some(id) => write!(f, "rj45: no PHY on MDIO addresses 0 to 31 (address 1 read {id:#010x}); trying again from the reset"),
                None => f.write_str("rj45: MDIO does not answer; trying again from the reset"),
            },
            Rj45Event::Phy(PhyEvent::Link { up, speed, full_duplex, usable }) => write!(
                f,
                "rj45: link {} {} Mbit/s {}{}",
                if up { "up" } else { "down" },
                speed,
                if full_duplex { "full" } else { "half" },
                if usable || !up { "" } else { " (not usable: the unit runs 100 Mbit/s full duplex only)" }
            ),
            Rj45Event::NoUnit => f.write_str("rj45: network unit not in this bitstream"),
        }
    }
}

/// The network unit with its PHY, identity and network clock.
pub struct Rj45Net<'a, R: RegisterSpace> {
    regs: &'a R,
    phy: Option<Phy>,
    identity: Identity,
    /// The link is up at 100 Mbit/s full duplex, the only mode the unit runs.
    usable: bool,
    /// DHCP, SNTP and the service socket on this unit.
    pub time: NetTime<'a>,
    events: [Option<Rj45Event>; 4],
}

impl<'a, R: RegisterSpace> Rj45Net<'a, R> {
    /// Reads the chip ID, sets the address and starts the PHY. `mac_setting` is an address stored on the board, which wins
    /// over the one made from the chip ID (the firmware has no settings store yet, so the caller passes `None`).
    pub fn new(regs: &'a R, store: &'a mut NetStore<'a>, now_us: u64, mac_setting: Option<[u8; 6]>) -> Self {
        let mut eth = Eth(regs);
        let mut chip_id = None;
        if eth.present() {
            for _ in 0..ID_WAIT_READS {
                chip_id = eth.chip_id();
                if chip_id.is_some() {
                    break;
                }
            }
        }
        let identity = Identity::new(chip_id, mac_setting);
        let time = NetTime::new(store, &mut eth, identity.mac, now_us);
        let mut n = Rj45Net { regs, phy: None, identity, usable: false, time, events: [None; 4] };
        if eth.present() {
            eth.set_mac(identity.mac);
            n.phy = Some(Phy::start(&eth, (now_us / 1000) as u32));
        } else {
            n.event(Rj45Event::NoUnit);
        }
        n
    }

    /// Chip ID, address and name of this board (printed once at start-up).
    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    fn event(&mut self, e: Rj45Event) {
        if let Some(slot) = self.events.iter_mut().find(|s| s.is_none()) {
            *slot = Some(e);
        }
    }

    /// The next thing to tell, oldest first.
    pub fn take_event(&mut self) -> Option<Rj45Event> {
        let e = self.events[0].take();
        self.events.rotate_left(1);
        e
    }

    /// Runs the PHY state machine and the network stack; call once per main-loop turn with the monotonic time in microseconds.
    pub fn poll(&mut self, now_us: u64) {
        let mut eth = Eth(self.regs);
        if let Some(phy) = self.phy.as_mut() {
            if let Some(e) = phy.poll(&eth, (now_us / 1000) as u32) {
                if let PhyEvent::Link { usable, .. } = e {
                    self.usable = usable;
                }
                self.event(Rj45Event::Phy(e));
            }
        }
        self.time.poll(&mut eth, self.usable, now_us);
    }

    /// Opens a UDP port on the unit's address for a firmware service (the PC's mouse and keyboard, `tr_input`); it
    /// takes effect once DHCP has given an address.
    pub fn serve_udp(&mut self, port: u16) {
        self.time.set_service_port(Some(port));
    }

    /// The next datagram of the service port: copied into `buf`, its true length, the sender's address and port.
    pub fn service_recv(&mut self, buf: &mut [u8]) -> Option<(usize, [u8; 4], u16)> {
        self.time.service_recv(buf)
    }

    /// Queues a datagram from the service port; it leaves in the next [`Rj45Net::poll`].
    pub fn service_send(&mut self, to: [u8; 4], port: u16, data: &[u8]) -> bool {
        self.time.service_send(to, port, data)
    }

    /// Our IPv4 address, once DHCP gave one.
    pub fn address(&self) -> Option<[u8; 4]> {
        self.time.address()
    }

    /// The link is up at 100 Mbit/s full duplex.
    pub fn link_up(&self) -> bool {
        self.usable
    }

    /// Whether the clock is set, and how old the setting is.
    pub fn state(&self, now_us: u64) -> TimeState {
        self.time.state(now_us)
    }

    /// UTC in milliseconds since 1970, once the network has set the clock.
    pub fn utc_ms(&self, now_us: u64) -> Option<i64> {
        self.time.utc_us(now_us).map(|us| us.div_euclid(1000))
    }
}
