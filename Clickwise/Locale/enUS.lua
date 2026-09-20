local L = LibStub("AceLocale-3.0"):NewLocale("Clickwise", "enUS", true)
if not L then return end

L["Clickwise"] = true
L["Only WotLK 3.3.5 is supported (this client reports interface %s). Clickwise is disabled."] = true
L["Frames are locked."] = true
L["Frames are unlocked. Drag the Clickwise tab to move them."] = true
L["Cannot move frames in combat."] = true
L["Position reset."] = true
L["Bindings reset to the %s class template."] = true
L["Bound %s to %s."] = true
L["Removed binding %s."] = true
L["No binding found for %s."] = true
L["Usage: /cw bind <[alt-][ctrl-][shift-]button> <spell name>   (button = 1-5)"] = true
L["Usage: /cw unbind <[alt-][ctrl-][shift-]button>"] = true
L["Invalid binding key %q. Use e.g. shift-1, ctrl-2, alt-3, 4."] = true
L["Changes will apply when combat ends."] = true

-- Options panel
L["Lock frames"] = true
L["Show pets"] = true
L["Class colored bars"] = true
L["Show tank / healer role icon"] = true
L["Range fade"] = true
L["Incoming heal prediction"] = true
L["Include my own heals"] = true
L["Horizontal layout"] = true
L["Scale"] = true
L["Frame width"] = true
L["Frame height"] = true
L["Frame spacing"] = true
L["Out-of-range alpha"] = true
L["Health text"] = true
L["None"] = true
L["Deficit"] = true
L["Percent"] = true
L["Reset position"] = true
L["Reset bindings to class template"] = true
L["Current click-cast bindings (/cw bind, /cw unbind)"] = true
L["No bindings for this class."] = true

-- Settings window
L["%s bindings"] = true
L["Action"] = true
L["Assist unit"] = true
L["Bindings"] = true
L["Buffs"] = true
L["Button 4"] = true
L["Button 5"] = true
L["Cast spell"] = true
L["Editing an existing binding."] = true
L["Enter the macro text."] = true
L["General"] = true
L["Group spacing"] = true
L["Heal look-ahead (seconds)"] = true
L["Highest known rank: %s (blank rank = always the highest)"] = true
L["In combat: changes apply when combat ends."] = true
L["Layout"] = true
L["Left"] = true
L["Left click"] = true
L["Left click = target and right click = unit menu unless you bind them here."] = true
L["Macro"] = true
L["Macro text (255 characters max)"] = true
L["Middle"] = true
L["Middle click"] = true
L["Modifiers"] = true
L["Mouse button"] = true
L["New"] = true
L["Not in your spellbook - it will still be saved."] = true
L["Rank (optional)"] = true
L["Remove"] = true
L["Replaces the existing binding: %s"] = true
L["Reset to class template"] = true
L["Right"] = true
L["Right click"] = true
L["Save binding"] = true
L["Search your spellbook"] = true
L["Set focus"] = true
L["Spell name"] = true
L["Target unit"] = true
L["This overrides the built-in target / menu click."] = true
L["Tip: [target=mouseover] in a macro acts on the frame under the cursor."] = true
L["Tip: unlock the frames, then drag the blue 'Clickwise' tab above them."] = true
L["Type or pick a spell."] = true
L["class template"] = true
L["custom"] = true

-- Interface Options entry
L["Open Clickwise settings"] = true
L["Clickwise now has its own settings window with tabs for General, Layout, Bindings and Buffs."] = true
L["You can also open it any time with /cw."] = true

-- Buff tracking
L["A click casts: %s"] = true
L["Also show buffs that are already up (dimmed)"] = true
L["Attack power"] = true
L["Blessing of Kings"] = true
L["Blessing of Sanctuary"] = true
L["Blessing of Wisdom"] = true
L["Buff"] = true
L["Buff group"] = true
L["Buff groups you can cast"] = true
L["Casts your highest-priority known spell of the group. Set the priority in the Buffs tab."] = true
L["Casts: %s"] = true
L["Down"] = true
L["Intellect"] = true
L["Mark of the Wild"] = true
L["Maximum health"] = true
L["Priority, highest first. A click bound to this group casts the first spell you know."] = true
L["Reset this group"] = true
L["Shadow Protection"] = true
L["Show missing buffs on the frames"] = true
L["Spirit"] = true
L["Stamina"] = true
L["Strength and agility"] = true
L["Thorns"] = true
L["To cast a buff with a click, add a binding in the Bindings tab with the action 'Buff group'."] = true
L["Up"] = true
L["You do not know a spell of this group - the binding will do nothing until you do."] = true
L["Your class has no buff spells Clickwise can track yet."] = true

-- Buff tracking
L["Add"] = true
L["Add a buff"] = true
L["Assigned buff"] = true
L["Assignments"] = true
L["Clear this rule"] = true
L["Damage dealers"] = true
L["Everyone else"] = true
L["Self"] = true
L["Healers"] = true
L["Buffs the unit lacks are cast in this order, one per click. Buffs that replace each other (a paladin's blessings) are alternatives: the first one nobody else provides."] = true
L["No assignments yet - set them up in the Assignments tab."] = true
L["Tanks"] = true
L["Who gets which buff"] = true

-- Buff tracking
L["Bind a click to 'Assigned buff' in the Bindings tab (it starts as out of combat only; 'Cast when' changes that). Your own frame uses the Self rule; any other unit its role's rule, else its class's, else Everyone else. If a tank is not recognised as one, use a class rule."] = true

-- Buff tracking
L["A buff you cast pulses on the frame, faster as it runs out, and is solid once it is gone. 0 turns the warning off."] = true
L["Warn before a buff runs out (seconds)"] = true

-- Buff tracking
L["Any time"] = true
L["Cast when"] = true
L["Casts the buff the Assignments tab picks for that unit: the first one in its list the unit does not already have. It starts as 'Out of combat'; change that with 'Cast when'."] = true
L["In combat"] = true
L["Only when neither you nor that player is fighting; this click does nothing in combat. Add an 'In combat' binding on the same click (a heal?)."] = true
L["Only when you or that player is fighting; this click does nothing out of combat. Add an 'Out of combat' binding on the same click (a buff?)."] = true
L["Out of combat"] = true
L["combat"] = true
L["ooc"] = true

-- Buff tracking
L["Automatic (by my role)"] = true
L["Combat colors"] = true
L["Health (healer)"] = true
L["In combat the bars turn green, then yellow, then red. Automatic: threat colors if you tank, health colors otherwise."] = true
L["Off"] = true
L["Red below health (%)"] = true
L["Threat (tank)"] = true
L["Threat warning (%)"] = true
L["Yellow at health (%)"] = true

-- Hover tooltip
L["Alt"] = true
L["Assist"] = true
L["Click bindings"] = true
L["Ctrl"] = true
L["Damage"] = true
L["Detailed"] = true
L["Focus"] = true
L["Healer"] = true
L["Health"] = true
L["Hold Alt, Ctrl or Shift for more."] = true
L["Menu"] = true
L["Missing"] = true
L["Out of range"] = true
L["Range"] = true
L["Role"] = true
L["Shift"] = true
L["Show buff status"] = true
L["Show click bindings"] = true
L["Someone else"] = true
L["Standard"] = true
L["Tank"] = true
L["Target"] = true
L["Unit tooltip"] = true
L["Yours"] = true

-- Debuff highlight
L["Debuffs"] = true
L["Highlight debuffs"] = true
L["Only debuffs I can remove"] = true
L["Show the debuff icon"] = true

-- Cure debuff click
L["Casts the spell that removes the worst debuff the unit has that you can remove (Cleanse, Remove Curse, Dispel Magic...). Only while you are out of combat: in combat, and when there is nothing to remove, the click does your other binding on the same click."] = true
L["Cure debuff"] = true
L["Nothing else is bound to this click, so it does nothing in combat. Bind a heal on the same click."] = true
L["Otherwise this click targets the unit."] = true
L["Otherwise this click: %s"] = true
L["Removes: %s"] = true
L["You know no spell that removes debuffs - this does nothing until you do."] = true

-- Resurrect click
L["Casts your resurrection on a dead or released member. Only while you are out of combat: on a living member, and in combat, the click does your other binding on the same click (a left click still targets)."] = true
L["Resurrect"] = true
L["You know no resurrection spell - this does nothing until you do."] = true

-- Profiles and the player's own role
L["Profiles"] = true
L["Automatic"] = true
L["My role"] = true
L["Profile: %s (this character: %s)."] = true
L["Also used by: %s."] = true
L["No other character uses this profile."] = true
L["Profiles: %s."] = true
L["Profile in use: %s"] = true
L["Shared with: %s. A change made here changes it for them too."] = true
L["Only this character uses it."] = true
L["A profile holds the frame layout, bindings, buff rules and every other setting. Each character gets a profile of its own the first time it logs in, so one character's setup never changes another's. Characters can share a profile on purpose."] = true
L["Use profile"] = true
L["New profile"] = true
L["Create and use"] = true
L["Copy settings from"] = true
L["Copy"] = true
L["Replaces everything in the profile in use."] = true
L["Reset this profile"] = true
L["Give this character its own profile"] = true
L["Delete profile"] = true
L["Delete"] = true
L["A different profile for each talent spec"] = true
L["Name font"] = true
L["Name size"] = true
L["Default font"] = true
L["Role look"] = true
L["A role look is on (Role look tab)."] = true
L["Use this look"] = true
L["Threat bar on tanks too"] = true
L["A role can have a look of its own. While you play it and its look is on, the frame size, heal prediction, debuff icon and threat bar below replace the ones on the General and Layout tabs. Everything else is shared by every role."] = true
L["Your role is not known yet, so the General and Layout settings are used."] = true
L["You play %s: its look is on."] = true
L["You play %s: its look is off, the General and Layout settings are used."] = true
L["The look of the %s role is on."] = true
L["A different profile for each role"] = true
L["A profile per role is on; you play %s."] = true
L["Spec %d"] = true
L["This character now has its own profile, a copy of the one it used."] = true
L["This character switched to its own profile."] = true
L["This character already has its own profile."] = true
L["Copied the settings of %s."] = true
L["Profile reset."] = true
L["Deleted profile %s."] = true

-- Taunt click
L["Taunt"] = true
L["Taunts the enemy this member is targeting, with your class's taunt (Taunt, Hand of Reckoning, Dark Command or Growl). Works in combat. A member with no enemy targeted: nothing happens."] = true
L["You know no taunt spell - this does nothing until you do."] = true
L["Test: your click casts %s on what %s is targeting."] = true

-- Threat (Threat.lua)
L["Threat"] = true
L["%d%% toward pulling"] = true
L["Aggro border"] = true
L["Threat bar"] = true
L["Red ring: has the enemy. Yellow: about to take it. Tanks and pets get none. The warning percentage is on the General tab."] = true

-- Test mode (Test.lua)
L["Test group: the frames are not built yet."] = true
L["Test group: %d made-up members, shown below your frames. Click one to see what your click would cast. /cw test combat switches combat colors, /cw test off ends it."] = true
L["Test group off."] = true
L["Test combat on."] = true
L["Test combat off."] = true
L["Start a test group first: /cw test"] = true
L["Usage: /cw test [5|10|25|40|off|combat]"] = true
L["Test: your click casts %s on %s."] = true
L["Test: your click casts nothing on %s right now."] = true
L["Test: your click targets %s."] = true
L["Test: your click opens the unit menu (not available on test frames)."] = true
L["Test: your click does %s, which test frames cannot show."] = true
L["Test group"] = true
L["Test combat"] = true
