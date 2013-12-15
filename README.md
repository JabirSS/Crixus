Crixus
======

Crixus is a preprocessing tool for SPH, in particular Spartacus3D, Sphynx and GPUSPH. In this document you will get some information on how to run Crixus and a description of its options.

-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

Table of contents
=================
1. Compiling Crixus
2. Creating an STL file for Crixus
3. Running Crixus
4. Getting help


1.) Compiling Crixus
--------------------

The installation and compilation procedure is described in the file INSTALL.

2.) Creating an STL file for Crixus
-----------------------------------

Before we start a few words on how to prepare a geometry. We will use the program SALOME (www.salome-platform.com) in the following, but any other program capable of generating \*.stl files can be used.

Salome offers several options to create a geometry:
1. Create the geometry by hand in Salome
2. Import a geometry
3. Import an STL file and convert it to a geometry

The last one needs to be described in greater detail. Open a new study in Salome (File->New) and switch to the mesh module. Import an STL file (File->Import->STL File) and rename it to "Mesh_import". After that load the script (File->Load Script) which is located in $(CRIXUS_PATH)/ressources/ and is called "convert_stl_to_geometry.py". Next switch to the geometry module and you should be able to see a geometry called "stl_geometry".

So by now you should have a geometry in Salome and in the next step we will create a triangle mesh. To start with that switch to the mesh module in Salome. Now create a new mesh (Mesh->Create Mesh). As geometry choose the geometry from the list on the left (in the above it was "stl_geometry"). There is no need for a 3D algorithm so switch to the 2D tab. Now several options are available and it is possibly a good idea to try several of them and compare the results against each other. The options are:

1. Netgen 2D
2. Netgen 1D-2D
3. Triangle (Mephisto)

In detail:
1. *Netgen 2D*: As hypothesis choose Length From Edges, then choose a 1D algorithm as outlined below.
2. *Netgen 1D-2D*: The "Netgen 2D Simple Parameters" suffice as hypothesis. In the 1D box choose "Local Length" as option and in the 2D box tick "Length from edges".
3. *Triangle*: No hypothesis required.

For option 1 and 3 a 1D algorithm is required, to select one switch to tab 1D and choose "Wire discretisation" as hypothesis choose "Max Length".

Now finally the last parameter is the characteristic length which needs to be set. Unfortunately the constraint required for Spartacus3D and Sphynx cannot be specified in any meshing tool. The constraint is as follows, the distance between a vertex particle (a triangle vertex) and a segment (located at the triangles barycentre) is allowed to be at most DR, which is the typical particle spacing. So for now I advise to take the length as approximately 3/2\*DR and then check if the distances are ok and then adapt accordingly. Since meshing usually doesn't take very long this should not be a major obstacle. Whether or not this constraint is fullfilled is checked by Crixus, as shown below, so it can be used to adapt the size.

Once the algorithms are set up, compute the mesh (Mesh->Compute) and export the resulting mesh as STL file (File->Export->STL File).

3.) Running Crixus
------------------

4.) Getting help
----------------

If you need any help or found a bug feel free to write me an email to firstname.initial@domain.tld where
- firstname = arno
- initial = m
- domain = gmx
- tld = at
Finally it shall be noted that the authors can be motivated by supplying them with whisky.
