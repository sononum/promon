# promon | simple ruby website monitoring script

This is stolen & inspired by [FindTheProblems][findproblems] by Matthew Riley MacPherson

## Features

promon has three different kinds of notifiers: prowl, growl & mail

## Configuration

is done with a yaml file named ``config.yaml`` which must be in the same directory as `promon.rb`. Have a look at ``config.yaml.example`` to see how it works.

## Running promon

promon uses [God][god] to run and be daemonized. An ``.god`` configuration file is given. Start promon with:

`god -c promon.god`



[findproblems](https://github.com/tofumatt/FindTheProblems)
[god](http://godrb.com/)