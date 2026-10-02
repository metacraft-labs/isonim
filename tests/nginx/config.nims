# The nginx fixture's modules are compiled from here (the browser client)
# and from ngx-isonim's build (the server side, with its own --path list).
switch("path", "$projectDir/../../src")
switch("path", "$projectDir/../../../nim-everywhere/src")
