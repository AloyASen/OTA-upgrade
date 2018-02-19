/*
Code originally from Aron Steg: http://forums.electricimp.com/discussion/comment/7904
Modified February 1st, 2014 by Nathan Seidle
Many great fixes were made by Aaron Steg, May 2014.

Currently, the only difference between this code and Aaron's original is we invert
the reset line logic to work with standard Arduinos.

Original license:

Copyright (c) 2014 Electric Imp
The MIT License (MIT)
http://opensource.org/licenses/MIT
*/

server.log("Agent started, URL is " + http.agenturl());

applet <- null;
program <- null;
loadAddress <- null;
device_ready <- null;

//------------------------------------------------------------------------------------------------------------------------------
html <- @"
<!doctype html>
<HTML lang='en'>
<head>
<meta name='viewport' content='width=device-width, initial-scale=1.0'>
<!-- Bootstrap -->
<!-- Latest compiled and minified CSS -->
<link rel='stylesheet' href='//maxcdn.bootstrapcdn.com/bootstrap/3.2.0/css/bootstrap.min.css'>
<!-- Optional theme -->
<link rel='stylesheet' href='//maxcdn.bootstrapcdn.com/bootstrap/3.2.0/css/bootstrap-theme.min.css'>
</head>
<BODY>
<div class='container'>
<h1>Avench OTA Demo for Atmel SAM D21</h1>

<form method='POST' enctype='multipart/form-data' id='form1'>
Step 1: Select SAMD21 Applet Binary file to upload: <input type=file name=applet-binary><br/>
</form>


<form method='POST' enctype='multipart/form-data' id='form2'>
Step 2: Select SAMD21 Program Binary file to upload: <input type=file name=program-binary><br/>
</form>


<form method='POST' enctype='multipart/form-data' id='form3'>
Step 3: Enter Program Load address:<input type=text placeholder='Program Load Address' name='load-address' value='0x1000' ><br/><br/>
</form>


<input type=submit value='Start Firmware Upgrade' onclick='submitForms()'>

<script src='//ajax.googleapis.com/ajax/libs/jquery/1.11.1/jquery.min.js'></script>
<script src='//maxcdn.bootstrapcdn.com/bootstrap/3.2.0/js/bootstrap.min.js'></script>
<script type='text/javascript'>

var delayMillis=1000;

submitForms = function(){
    document.getElementById('form3').submit();
    
    setTimeout(function(){
         document.getElementById('form1').submit();
    },delayMillis);
    setTimeout(function(){
         document.getElementById('form2').submit();
    },delayMillis*4);
}
</script>


<!--
<h2>OR</h2>
<div class='panel panel-default'>
<div class='panel-heading' id='dropbox-button'></div>
<div class='panel-body'>
<table class='table'>
<thead>
<tr>
<th>#</th>
<th>File Name</th>
<th>Action</th>
</tr>
</thead>
<tbody id='link-text'>
</tbody>
</table>
</div>
</div>
</div>


<script type='text/javascript' src='//www.dropbox.com/static/api/2/dropins.js' id='dropboxjs' data-app-key='8jsgtlv8g2xgq9s'></script>
<script type='text/javascript'>
function uploadFile(fileLink) {
  $('#hex-file').val(fileLink);
  $('#hex-upload-form').submit();
}
function buildLinkRow(idx, fileLink) {
  $('#link-text').append('<tr id=\'link-row-'+idx+'\'><td>'+idx+'</td><td>'+fileLink+'</td><td><button type=button id=upload-button-'+idx+' class=\'btn btn-default\'><span class=\'glyphicon glyphicon-upload\'></span></button><button type=button id=\'remove-button-'+idx+'\' class=\'btn btn-default\'><span class=\'glyphicon glyphicon-remove\'></span></button></td></tr>');
  $('#upload-button-'+idx).click({value: fileLink}, function(e) {
    uploadFile(e.data.value);
  });
  $('#remove-button-'+idx).click({value: idx, link: fileLink}, function(e) {
    $('#link-row-'+e.data.value).remove();
    links.splice(idx - 1, 1);
    buildLinkTable();
  });
}
function buildLinkTable() {
  $('#link-text').empty();
  if( links.length > 0 ) {
    for( var i=0; i < links.length; i++ ) {
      buildLinkRow(i+1, links[i]);
    } 
    if( window.localStorage ) localStorage['links'] = JSON.stringify(links);
  } else {
    $('#link-text').append('<tr id=\'empty-row\'><td colspan=3>Please select a file.</td></tr>');
  }
}
</script>

<script type='text/javascript'>
options = {
    success: function(files) {
      links.push(files[0].link);
      buildLinkTable();
    },
    cancel: function() {

    },
    linkType: 'direct',
    multiselect: false, 
    extensions: ['.hex', '.bin']
};
var button = Dropbox.createChooseButton(options);
$('#dropbox-button').html(button);

var emptyRow;
var links = [];
if( window.localStorage ) {
  var linksStr = localStorage['links'];
  if( linksStr ) {
    links = JSON.parse(linksStr);
  }
} else {
  console.log('local storage not supported...');
}
buildLinkTable();
</script>
-->

</BODY>
</HTML>
";

//------------------------------------------------------------------------------------------------------------------------------
// Convert an hex string to integer value
function hexStringToInt(hexString) {
    // Does the string start with '0x'? If so, remove it
    if (hexString.slice(0, 2) == "0x") hexString = hexString.slice(2);

    // Get the integer value of the remaining string
    local intValue = 0;

    foreach (character in hexString) {
        local nibble = character - '0';
        if (nibble > 9) nibble = ((nibble & 0x1F) - 7);
        intValue = (intValue << 4) + nibble;
    }

    return intValue;
}

//------------------------------------------------------------------------------------------------------------------------------
// Parses a HTTP POST in multipart/form-data format
function parse_binpost(req, res) {
    server.log("Method: " + req.method);
    //server.log("Header" + req.headers);
    server.log(format("Body: %s\r\n", req.body));
    
    local boundary = req.headers["content-type"].slice(30);
    //server.log("boundary" + boundary);
    local bindex = req.body.find(boundary);
    //server.log("bindex" + bindex);
    local hstart = bindex + boundary.len();
    //server.log("hstart" + hstart);
    local bstart = req.body.find("\r\n\r\n", hstart) + 4;
    //server.log("bstart" + bstart);
    local fstart = req.body.find("\r\n--" + boundary + "--", bstart);
    //server.log("fstart" + fstart);
    local body = req.body.slice(bstart, fstart);
    
    return body;
}

//------------------------------------------------------------------------------------------------------------------------------
// Create applet blob from request
function create_applet_blob(bin)
{
    server.log("Creating Applet Blob");
    
    // Create and blank the applet blob
    applet = blob();
    for (local i = 0; i < applet.len(); i++) 
    {
        applet.writen(0x00, 'b');
    }
    
    applet.seek(0);
    
    applet.writestring(bin);
    
    local str = applet.tostring();
    server.log(str);
    
    server.log("Free RAM: " + (imp.getmemoryfree()/1024) + " kb")
    server.log("Applet File Received");
}

//------------------------------------------------------------------------------------------------------------------------------
// Create program blob from request
function create_program_blob(bin)
{
    server.log("Creating Program Blob");
    
    // Create and blank the program blob
    program = blob();
    for (local i = 0; i < program.len(); i++) 
    {
        program.writen(0x00, 'b');
    }
    
    program.seek(0);
    
    program.writestring(bin);
    
    local str = program.tostring();
    server.log(str);
    
    server.log("Free RAM: " + (imp.getmemoryfree()/1024) + " kb")
    server.log("Program File Received");
}

//------------------------------------------------------------------------------------------------------------------------------
// Send applet binary to the device
function send_applet() {
    if (applet != null && applet.len() > 0) {
        server.log("Sending Applet");
        device.send("applet_binary", applet);
    }
}  

//------------------------------------------------------------------------------------------------------------------------------
// Send load address to the device
function send_load_address() {
    if (loadAddress != null) {
        server.log("Sending Load Address");
        device.send("load_address", loadAddress);
    }
}        

//------------------------------------------------------------------------------------------------------------------------------
// Send program binary to the device
function send_program() {
    if (program != null && program.len() > 0) {
        server.log("Sending Program");
        device.send("program_binary", program);
    }
} 

//------------------------------------------------------------------------------------------------------------------------------
// Handle the agent requests
http.onrequest(function (req, res) {
    // return res.send(400, "Bad request");
    // server.log(req.method + " to " + req.path)
    if (req.method == "GET") {
        if(device_ready == true)
            res.send(200, html);
    } else if (req.method == "POST") {

        if ("content-type" in req.headers) {
            if (req.headers["content-type"].len() >= 19
             && req.headers["content-type"].slice(0, 19) == "multipart/form-data") {
                 if(req.body.find("applet-binary") != null)
                 {
                    server.log("Applet File");
                    local bin = parse_binpost(req, res);
                    if (bin == "") {
                        res.header("Location", http.agenturl());
                        res.send(302, "Applet file uploaded");
                    } else {
                        device.on("applet_received", function(ready) {
                            res.header("Location", http.agenturl());
                            res.send(302, "Applet sent");   
                            server.log("Applet sent");
                            send_load_address();
                        });
                    create_applet_blob(bin);
                    }
                }
                else if(req.body.find("load-address") != null)
                {
                    server.log("Load Address");
                    local address = parse_binpost(req, res);
                    loadAddress = hexStringToInt(address);
                    if (loadAddress == "") {
                        res.header("Location", http.agenturl());
                        res.send(302, "Load Address Sent");
                    } else 
                    {
                        device.on("load_address_received", function(ready) {
                            res.header("Location", http.agenturl());
                            res.send(302, "Load Address sent");   
                            server.log("Load Address sent");
                            send_program();
                        });
                        server.log(format("Load Address: %X", loadAddress));
                    }
                }
                else if(req.body.find("program-binary") != null)
                {
                    server.log("Program File");
                    local bin = parse_binpost(req, res);
                    if (bin == "") {
                        res.header("Location", http.agenturl());
                        res.send(302, "Program file uploaded");
                    } else {
                        device.on("program_received", function(ready) {
                            res.header("Location", http.agenturl());
                            res.send(302, "Program sent");   
                            server.log("Program sent");
                            device.send("start_ota", true);
                        });
                    create_program_blob(bin);
                    send_applet();
                    }
                }                
            } else if (req.headers["content-type"] == "application/json") {
                local json = null;
                try {
                    json = http.jsondecode(req.body);
                } catch (e) {
                    server.log("JSON decoding failed for: " + req.body);
                    return res.send(400, "Invalid JSON data");
                }
                local log = "";
                foreach (k,v in json) {
                    if (typeof v == "array" || typeof v == "table") {
                        foreach (k1,v1 in v) {
                            log += format("%s[%s] => %s, ", k, k1, v1.tostring());
                        }
                    } else {
                        log += format("%s => %s, ", k, v.tostring());
                    }
                }
                server.log(log)
                return res.send(200, "OK");
            } else if(req.headers["content-type"] == "application/x-www-form-urlencoded") {
              server.log(req.body);
              local data = http.urldecode(req.body);
              local url = data.hexfile;
              server.log("url: " + url);
              local bin = http.get(url).sendsync();
              //server.log("hex: " + hex.body);
              device.on("done", function(ready) {
                  res.header("Location", http.agenturl());
                  res.send(302, "BIN file uploaded");                        
                  server.log("Programming completed")
              })
              server.log("Programming started")
              //parse_hexfile(bin.body);              
            } else {          
                return res.send(400, "Bad request");
            }
        } else {
            return res.send(400, "Bad request");
        }
    }
})


//------------------------------------------------------------------------------------------------------------------------------
// Handle OTA Success message from Device
device.on("ota-complete", function(done) {
    if (done) server.log("Firmware Update Complete!!!");
});

//------------------------------------------------------------------------------------------------------------------------------
// Handle OTA Failure message from Device
device.on("ota-fail", function(status) {
   if (status) server.log("Firmware Update Failed!!!"); 
});

//------------------------------------------------------------------------------------------------------------------------------
// Handle the device coming online
device.on("ready", function(ready) {
    if (ready) device_ready = true;
});
