/*
Code originally from Aron Steg: http://forums.electricimp.com/discussion/comment/7904
Modified February 1st, 2014 by Nathan Seidle
Many great fixes were made by Aaron Steg, May 2014.

This code was modified slightly to work with the Electric Imp Shield 
from SparkFun: https://www.sparkfun.com/products/11401
The reset control was inverted and status LEDs re-routed but everything else was the same.
Zomg thank you Aron Steg: http://forums.electricimp.com/discussion/comment/7904

Two hardware modifications are required:

* Cut two RX/TX traces to 8/9 on the back of the Imp Shield then solder blob to 0/1
* Wire from P1 of Imp to RST on shield.

It takes the Arduino approximately 400ms from reset going high to be able to 
respond to incoming bootload commands.

Original license:

Copyright (c) 2014 Electric Imp
The MIT License (MIT)
http://opensource.org/licenses/MIT

*/
//------------------------------------------------------------------------------------------------------------------------------
// Constant defenitions
const SOH = 0x01;
const EOT = 0x04;
const XMODEM_FRAME_SIZE = 133;
const DATA_FRAME_SIZE = 128;

const APPLET_ADDR = 0x20000470;
const APPLET_CMD_REG = 0x200004B0;
const APPLET_BUFF_ADDR_REG = 0x200004B8;
const APPLET_BUFF_LEN_REG = 0x200004BC;
const APPLET_FLASH_WRITE_ADDR_REG = 0x200004C0;
const APPLET_BUFF_ADDR = 0x20000CD0;
const APPLET_BUFF_LEN = 0x00000100;
const APPLET_FLASH_WRITE_ADDR = 0x00001000;

const IMP_SUCCESS = 0;
const IMP_FAIL = 1;

//------------------------------------------------------------------------------------------------------------------------------
// Applet Flash Commands
enum appletCmd
{
    init,
    fullErase,
    write,
    read
};

//------------------------------------------------------------------------------------------------------------------------------
// Global variables
applet <- null;
program <- null;
loadAddress <- null;

FrameNo <- null;
InvFrameNo <- null;
device_ready <- null;
readCount <- null;
applet_flash_write_addr <- null;

applet_flash_write_addr = APPLET_FLASH_WRITE_ADDR;

server.log("Device started, device_id " + hardware.getdeviceid());

//------------------------------------------------------------------------------------------------------------------------------
// Gpio to force AT-SAMD21 Bootloader
AT_BOOTLOADER_GPIO <- hardware.pinD;
AT_BOOTLOADER_GPIO.configure(DIGITAL_OUT, 1);
AT_RESET_GPIO <- hardware.pinB;
AT_RESET_GPIO.configure(DIGITAL_OUT, 1);

//------------------------------------------------------------------------------------------------------------------------------
// Uart2 for TX/RX
SERIAL <- hardware.uart2;
SERIAL.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS);

//------------------------------------------------------------------------------------------------------------------------------
// Reset Atmel Device
function reset_at_device()
{
    AT_RESET_GPIO.write(0);
    imp.sleep(0.2);
    AT_RESET_GPIO.write(1);
    imp.sleep(0.3);
}

//------------------------------------------------------------------------------------------------------------------------------
// Put Atmel device into UART Bootloader mode
function force_at_bootloader_mode()
{
    server.log("Forcing SAMD21 Bootloader Mode...");
    AT_BOOTLOADER_GPIO.write(0);
    reset_at_device();
    AT_BOOTLOADER_GPIO.write(1);
    imp.sleep(0.5);
}

//------------------------------------------------------------------------------------------------------------------------------
// Calculate 16 bit CRC-CCITT of incoming blob
function calculate_crc(data, count)
{
    local  crc;
    local i;
    crc = 0 & 0xFFFF; //seperate out only 4 bits for crc
    data.seek(0);
    while (--count >= 0)
    {
        crc = (crc ^  (data.readn('b') | 0x0000) << 8) & 0xFFFF;
        //server.log(format("crc: %04x", crc));
        i = 8;
        do
        {
            if (crc & 0x8000)
                crc = crc << 1 ^ 0x1021;
            else
                crc = crc << 1;
        } while(--i);
    }
    return (crc & 0xFFFF);
}

//------------------------------------------------------------------------------------------------------------------------------
// Receive Applet Binary from Agent
function receive_applet(applet_binary) 
{
    applet = applet_binary.readblob(applet_binary.len());
    server.log("Applet received");
    local str = applet.tostring();
    server.log(str);
    agent.send("applet_received", true);
}

//------------------------------------------------------------------------------------------------------------------------------
// Receive Load Address from Agent
function receive_load_address(loadAddress_value) 
{
    loadAddress = loadAddress_value;
    server.log(format("Load Address: %X Received", loadAddress));
    imp.sleep(0.5);
    agent.send("load_address_received", true);
}

//------------------------------------------------------------------------------------------------------------------------------
// Receive Program Binary from Agent
function receive_program_binary(program_binary) 
{
    program = program_binary.readblob(program_binary.len());
    server.log("Program received");
    local str = program.tostring();
    server.log(str);
    agent.send("program_received", true);
}

//------------------------------------------------------------------------------------------------------------------------------
// Load Applet Binary into memory
function load_applet() 
{
    server.log("Loading Applet");
    
    readCount = 0;
    
    force_at_bootloader_mode();
    
    SERIAL.write("#");
    imp.sleep(0.01);
    SERIAL.write("N#");
    imp.sleep(0.01);
    local applet_size = applet.len();
    server.log(applet_size);
    SERIAL.write(format("S%08X,%08X#", APPLET_ADDR, applet_size));

    while(readCount <= 1000 )
    {
        local data = SERIAL.read();
        local byte = data & 0xFF;
        
        readCount++;
        
        //server.log(format("%c", byte));
        
        if(byte == 'C')
        {
            readCount = 0;
            server.log(format("%c", byte));
            break;
        }
    }
    
    if(readCount > 0)
    {
        readCount = 0;
        server.log("Device not responding. Aborting Firmware Upgrade!!");
        return IMP_FAIL;
    }
    
    local last_frame = false;
    applet.seek(0);
    local data_frame = blob(DATA_FRAME_SIZE);
    local xmodem_packet = blob(XMODEM_FRAME_SIZE);
    FrameNo = 0x00;
    
    while((applet.tell() + DATA_FRAME_SIZE) <= applet.len())
    {
        if((applet.tell() + DATA_FRAME_SIZE) == applet.len())
        {
            last_frame = false;
        }
        else
        {
            last_frame = true;
        }
        xmodem_packet.seek(0);
        data_frame.seek(0);
        for (local i = 0; i < xmodem_packet.len(); i++) xmodem_packet.writen(0x00, 'b');
        for (local i = 0; i < data_frame.len(); i++) data_frame.writen(0x00, 'b');
        xmodem_packet.seek(0);
        data_frame.seek(0);
        xmodem_packet.writen(SOH, 'b');
        xmodem_packet.writen(++FrameNo, 'b');
        InvFrameNo = ~FrameNo & 0xFF;
        server.log(format("F: %x, I: %x\r\n", FrameNo, InvFrameNo));
        xmodem_packet.writen(InvFrameNo, 'b');
        data_frame = applet.readblob(DATA_FRAME_SIZE);
        local str = data_frame.tostring();
        server.log(str);
        xmodem_packet.writeblob(data_frame);
        local crc = calculate_crc(data_frame,data_frame.len());
        server.log(format("CRC: %x\r\n", crc));
        crc = swap2(crc);
        xmodem_packet.writen(crc, 'w');
        SERIAL.write(xmodem_packet);
        while(readCount <= 1000)
        {
            local data = SERIAL.read();
            local byte = data & 0xFF;
            
            readCount++;
            
            //server.log(format("%c", byte));
            
            if(byte == 0x06)
            {
                readCount = 0;
                server.log(format("%d", byte));
                break;
            }
        }
        
        if(readCount > 0)
        {
            readCount = 0;
            server.log("Device not responding. Aborting Firmware Upgrade!!");
            return IMP_FAIL;
        }
        str = xmodem_packet.tostring();
        server.log(str);
    }
    
    if(last_frame == true)
    {
        last_frame == false;
        xmodem_packet.seek(0);
        data_frame.seek(0);
        for (local i = 0; i < xmodem_packet.len(); i++) xmodem_packet.writen(0x00, 'b');
        for (local i = 0; i < data_frame.len(); i++) data_frame.writen(0x00, 'b');
        xmodem_packet.seek(0);
        data_frame.seek(0);
        xmodem_packet.writen(SOH, 'b');
        xmodem_packet.writen(++FrameNo, 'b');
        InvFrameNo = ~FrameNo & 0xFF;
        server.log(format("F: %x, I: %x\r\n", FrameNo, InvFrameNo));
        xmodem_packet.writen(InvFrameNo, 'b');
        local temp_buff = applet.readblob(applet.len() - applet.tell());
        local str = temp_buff.tostring();
        server.log(str);
        server.log(temp_buff.len());
        
        for(local i=0; i<DATA_FRAME_SIZE; i++)
        {
            if(i < temp_buff.len())
            {
                data_frame.writen(temp_buff.readn('c'), 'c');
            }
            else
            {
                data_frame.writen( 0x00, 'c');
            }
        }
        
        local str = data_frame.tostring();
        server.log(str);
        server.log(data_frame.len());
        
        xmodem_packet.writeblob(data_frame);
        local crc = calculate_crc(data_frame,data_frame.len());
        server.log(format("CRC: %x\r\n", crc));
        crc = swap2(crc);
        xmodem_packet.writen(crc, 'w');
        SERIAL.write(xmodem_packet);
        while(readCount <= 1000)
        {
            local data = SERIAL.read();
            local byte = data & 0xFF;
            
            readCount++;
            
            //server.log(format("%c", byte));
            
            if(byte == 0x06)
            {
                readCount = 0;
                server.log(format("%d", byte));
                break;
            }
        }
        
        if(readCount > 0)
        {
            readCount = 0;
            server.log("Device not responding. Aborting Firmware Upgrade!!");
            return IMP_FAIL;
        }
        
        SERIAL.write(EOT);
        str = xmodem_packet.tostring();
        server.log(str);
    }

    server.log("Applet-loaded!")
    return IMP_SUCCESS;
}

//------------------------------------------------------------------------------------------------------------------------------
// Burn Program into Flash
function burn_program() 
{
    server.log("Burning Program");
    
    local applet_cmd =  appletCmd.init;
    local applet_buff_addr = 1;
    local applet_buff_len = 1;
    applet_flash_write_addr = 0;
    
    SERIAL.write(format("W%08X,%08X#", APPLET_CMD_REG, applet_cmd));
    imp.sleep(0.00025);
    SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_ADDR_REG, applet_buff_addr));
    imp.sleep(0.00025);
    SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_LEN_REG, applet_buff_len));
    imp.sleep(0.00025);
    SERIAL.write(format("W%08X,%08X#", APPLET_FLASH_WRITE_ADDR_REG, applet_flash_write_addr));
    imp.sleep(0.00025);  
    SERIAL.write(format("G%08X#", APPLET_ADDR));
    imp.sleep(0.025);
    SERIAL.write(format("S%08X,%08X#", APPLET_BUFF_ADDR, APPLET_BUFF_LEN));

    while(readCount <= 1000)
    {
        local data = SERIAL.read();
        local byte = data & 0xFF;
        
        readCount++;
        
        //server.log(format("%c", byte));
        
        if(byte == 'C')
        {
            readCount = 0;
            server.log(format("%c", byte));
            break;
        }
    }
    
    if(readCount > 0)
    {
        readCount = 0;
        server.log("Device not responding. Aborting Firmware Upgrade!!");
        return IMP_FAIL;
    }
    
    applet_cmd =  appletCmd.write;
    applet_buff_addr = APPLET_BUFF_ADDR;
    applet_buff_len = APPLET_BUFF_LEN;
    applet_flash_write_addr = loadAddress;

    local last_frame = false;
    program.seek(0);
    local data_frame = blob(DATA_FRAME_SIZE);
    local xmodem_packet = blob(XMODEM_FRAME_SIZE);
    FrameNo = 0x00;
    
    while((program.tell() + DATA_FRAME_SIZE) <= program.len())
    {
        if((program.tell() + DATA_FRAME_SIZE) == program.len())
        {
            last_frame = false;
        }
        else
        {
            last_frame = true;
        }
        
        if(FrameNo == 2)
        {
            SERIAL.write(EOT);
            FrameNo = 0;
            
            SERIAL.write(format("W%08X,%08X#", APPLET_CMD_REG, applet_cmd));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_ADDR_REG, applet_buff_addr));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_LEN_REG, applet_buff_len));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_FLASH_WRITE_ADDR_REG, applet_flash_write_addr));
            imp.sleep(0.00025);  
            SERIAL.write(format("G%08X#", APPLET_ADDR));
            imp.sleep(0.025);
            SERIAL.write(format("S%08X,%08X#", APPLET_BUFF_ADDR, APPLET_BUFF_LEN));

            while(readCount <= 1000)
            {
                local data = SERIAL.read();
                local byte = data & 0xFF;
                
                readCount++;
                
                //server.log(format("%c", byte));
                
                if(byte == 'C')
                {
                    readCount = 0;
                    server.log(format("%c", byte));
                    break;
                }
            }
            
            if(readCount > 0)
            {
                readCount = 0;
                server.log("Device not responding. Aborting Firmware Upgrade!!");
                return IMP_FAIL;
            }
            
            applet_flash_write_addr += 0x100;
        }
        
        xmodem_packet.seek(0);
        data_frame.seek(0);
        for (local i = 0; i < xmodem_packet.len(); i++) xmodem_packet.writen(0x00, 'b');
        for (local i = 0; i < data_frame.len(); i++) data_frame.writen(0x00, 'b');
        xmodem_packet.seek(0);
        data_frame.seek(0);
        xmodem_packet.writen(SOH, 'b');
        xmodem_packet.writen(++FrameNo, 'b');
        InvFrameNo = ~FrameNo & 0xFF;
        server.log(format("F: %x, I: %x\r\n", FrameNo, InvFrameNo));
        xmodem_packet.writen(InvFrameNo, 'b');
        data_frame = program.readblob(DATA_FRAME_SIZE);
        local str = data_frame.tostring();
        server.log(str);
        xmodem_packet.writeblob(data_frame);
        local crc = calculate_crc(data_frame,data_frame.len());
        server.log(format("CRC: %x\r\n", crc));
        crc = swap2(crc);
        xmodem_packet.writen(crc, 'w');
        SERIAL.write(xmodem_packet);
        while(readCount <= 1000)
        {
            local data = SERIAL.read();
            local byte = data & 0xFF;
            
            readCount++;
            
            //server.log(format("%c", byte));
            
            if(byte == 0x06)
            {
                readCount = 0;
                server.log(format("%d", byte));
                break;
            }
        }
        
        if(readCount > 0)
        {
            readCount = 0;
            server.log("Device not responding. Aborting Firmware Upgrade!!");
            return IMP_FAIL;
        }        
        str = xmodem_packet.tostring();
        server.log(str);
    }
    
    if(last_frame == true)
    {
        last_frame == false;
        
        if(FrameNo == 2)
        {
            SERIAL.write(EOT);
            FrameNo = 0;
            
            SERIAL.write(format("W%08X,%08X#", APPLET_CMD_REG, applet_cmd));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_ADDR_REG, applet_buff_addr));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_LEN_REG, applet_buff_len));
            imp.sleep(0.00025);
            SERIAL.write(format("W%08X,%08X#", APPLET_FLASH_WRITE_ADDR_REG, applet_flash_write_addr));
            imp.sleep(0.00025);  
            SERIAL.write(format("G%08X#", APPLET_ADDR));
            imp.sleep(0.025);
            SERIAL.write(format("S%08X,%08X#", APPLET_BUFF_ADDR, 0x08));

            while(readCount <= 1000)
            {
                local data = SERIAL.read();
                local byte = data & 0xFF;
                
                readCount++;
                
                //server.log(format("%c", byte));
                
                if(byte == 'C')
                {
                    readCount = 0;
                    server.log(format("%c", byte));
                    break;
                }
            }
            
            if(readCount > 0)
            {
                readCount = 0;
                server.log("Device not responding. Aborting Firmware Upgrade!!");
                return IMP_FAIL;
            }
        }
        
        xmodem_packet.seek(0);
        data_frame.seek(0);
        for (local i = 0; i < xmodem_packet.len(); i++) xmodem_packet.writen(0x00, 'b');
        for (local i = 0; i < data_frame.len(); i++) data_frame.writen(0x00, 'b');
        xmodem_packet.seek(0);
        data_frame.seek(0);
        xmodem_packet.writen(SOH, 'b');
        xmodem_packet.writen(++FrameNo, 'b');
        InvFrameNo = ~FrameNo & 0xFF;
        server.log(format("F: %x, I: %x\r\n", FrameNo, InvFrameNo));
        xmodem_packet.writen(InvFrameNo, 'b');
        local temp_buff = program.readblob(program.len() - program.tell());
        local str = temp_buff.tostring();
        server.log(str);
        server.log(temp_buff.len());
        
        for(local i=0; i<DATA_FRAME_SIZE; i++)
        {
            if(i < temp_buff.len())
            {
                data_frame.writen(temp_buff.readn('c'), 'c');
            }
            else
            {
                data_frame.writen( 0x00, 'c');
            }
        }
        
        local str = data_frame.tostring();
        server.log(str);
        server.log(data_frame.len());
        xmodem_packet.writeblob(data_frame);
        xmodem_packet.seek(DATA_FRAME_SIZE - data_frame.len(), 'c');
        local crc = calculate_crc(data_frame,data_frame.len());
        server.log(format("CRC: %x\r\n", crc));
        crc = swap2(crc);
        xmodem_packet.writen(crc, 'w');
        SERIAL.write(xmodem_packet);
        while(readCount <= 1000)
        {
            local data = SERIAL.read();
            local byte = data & 0xFF;
            
            readCount++;
            
            //server.log(format("%c", byte));
            
            if(byte == 0x06)
            {
                readCount = 0;
                server.log(format("%d", byte));
                break;
            }
        }
        
        if(readCount > 0)
        {
            readCount = 0;
            server.log("Device not responding. Aborting Firmware Upgrade!!");
            return IMP_FAIL;
        }  
        SERIAL.write(EOT);
        
        applet_cmd =  appletCmd.write;
        applet_buff_addr = APPLET_BUFF_ADDR;
        applet_buff_len = 0x00000008;
        applet_flash_write_addr += 0x100;
        
        SERIAL.write(format("W%08X,%08X#", APPLET_CMD_REG, applet_cmd));
        imp.sleep(0.00025);
        SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_ADDR_REG, applet_buff_addr));
        imp.sleep(0.00025);
        SERIAL.write(format("W%08X,%08X#", APPLET_BUFF_LEN_REG, applet_buff_len));
        imp.sleep(0.00025);
        SERIAL.write(format("W%08X,%08X#", APPLET_FLASH_WRITE_ADDR_REG, applet_flash_write_addr));
        imp.sleep(0.00025);  
        SERIAL.write(format("G%08X#", APPLET_ADDR));
        imp.sleep(0.025);
        
        str = xmodem_packet.tostring();
        server.log(str);
    }

    server.log("Program-burn-complete!")
    reset_at_device();
    
    return IMP_SUCCESS;
}

//------------------------------------------------------------------------------------------------------------------------------
// Start Device Firmware Upgrade
function start_firmware_upgrade(ready)
{ 
    local Status;
    server.log("Starting OTA");
    
    Status = load_applet();
    if(Status != IMP_SUCCESS)
    {
        agent.send("ota-fail", true);
        return IMP_FAIL;
    }
    
    Status = burn_program();
    if(Status != IMP_SUCCESS)
    {
        agent.send("ota-fail", true);
        return IMP_FAIL;
    }
    server.log("OTA Complete");
    imp.sleep(2);
    agent.send("ota-complete", true);
}

//------------------------------------------------------------------------------------------------------------------------------
// Handle messages coming from Agent
agent.on("applet_binary", receive_applet);
agent.on("load_address", receive_load_address);
agent.on("program_binary", receive_program_binary);
agent.on("start_ota", start_firmware_upgrade);

// Send ready signal to Agent
agent.send("ready", true);
